//
//  VerifyViewModel.swift
//  雪宝 K歌麦克风 · 极简验证版
//
//  把网络 + 音频引擎包一层，UI 只跟它打交道。
//  参数改动统一走 `applyParameters()`，避免散落各处。
//

import SwiftUI
import Combine
import AVFoundation

final class VerifyViewModel: ObservableObject {

    // MARK: - 组件

    /// 盒子 IP。
    ///
    /// ★ 第二十三轮：**不再写死 192.168.1.5**。
    ///   那个值是我早期硬编码的，盒子 DHCP 一变就失效（实测 .5 → .10 → …），
    ///   用户每次打开 App 看到的都是错的，还得手动改。
    ///   现在：优先用上次成功连过的 IP；没有就留空，等自动扫描填上。
    @Published var boxIP: String = UserDefaults.standard.string(forKey: "lastBoxIP") ?? ""
    @Published private(set) var isConnected = false
    /// 网络状态镜像。`network` 是 let 常量，它内部变了不会通知 UI，
    /// 所以必须在这里复制一份成 @Published，SwiftUI 才会在 ready 时切界面。
    @Published private(set) var isNetworkReady = false
    @Published private(set) var networkStatusText: String = "未连接"
    /// 盒子名称（hello_ack 里带回来的），同样要镜像才能触发 UI 刷新
    @Published private(set) var deviceName: String = ""

    // ★ 从 let 改成 var：换盒子 IP 时需要重建实例。
    //   原来它们是 let，导致 connect(boxIP:) 里的 IP 参数无效。
    var network: NetworkController
    var audio: AudioEngineController

    // MARK: - 监测数据（从 audio 镜像到 UI）

    @Published var currentLevelDb: Float = -120
    @Published var erle: Float = 0
    @Published var howlingDetected = false
    @Published var howlingFreqs: [Float] = []
    @Published var isSinging = false
    @Published var sentFrames: Int = 0
    /// ★ 新增（第十三轮）：Int16 量化**之后**真正发出去的幅度（dBFS）。
    ///
    /// 这是判断「电视有没有声音」的唯一可靠指标。
    /// 与 `currentLevelDb`（AEC 之前的 Float）的区别：
    /// 幅度低于 1/32768 的样本在 Int16 里会全部量化成 0，
    /// 于是发出去的是纯零字节 —— 而输入电平看起来一切正常。
    @Published var sentLevelDb: Float = -120
    @Published var levelHistory: [Float] = Array(repeating: -60, count: 60)

    // MARK: - DSP 参数（UI 直接改这些）

    @Published var aecOn = true { didSet { apply() } }
    @Published var aecStrength: Double = 0.75 { didSet { apply() } }
    @Published var howlOn = true { didSet { apply() } }
    @Published var howlStrength: Double = 0.6 { didSet { apply() } }
    @Published var inputGain: Double = 0 { didSet { apply() } }
    @Published var reverb: Double = 0.12 { didSet { apply() } }
    @Published var reverbPreset: ReverbPreset = .smallRoom { didSet { apply() } }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    init() {
        let net = NetworkController(host: "192.168.1.5")
        self.network = net
        self.audio = AudioEngineController(network: net)

        // 音频引擎 → UI 的数据镜像（1 秒一次足够，省电也不拖慢音频线程）
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.syncFromAudio() }
            .store(in: &cancellables)

        // 网络状态 → UI。用NetworkController 自带的 onStateChange 回调，
        // 比轮询更准（连接成功的瞬间就能刷新界面）。
        // 注意：回调发生在 NetworkConnection 的队列上，必须切回主线程。
        net.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.applyNetworkState(state)
            }
        }
    }    // ← init() 结束

    private func applyNetworkState(_ state: NetworkController.State) {
        isNetworkReady = (state == .ready)
        networkStatusText = state.text

        // 连接就绪 → 立刻启动音频采集（只启动一次）
        if state == .ready && !isConnected {
            startAudio()
        }
    }

    // MARK: - 自动发现盒子

    /// 启动时开始自动扫描局域网里的盒子。
    ///
    /// ★ 为什么需要（第 17 轮的教训）：
    ///   盒子 IP 由 DHCP 分配会变（实测 .5 → .10），
    ///   手动改 IP 既容易忘又容易打错。
    ///   盒子端本来就在每秒广播自己的 IP（discover_reply），
    ///   我们直接监听就好 —— 用户一次配置都不用改。
    func startDiscovery() {
        discovery.start()
        // 订阅扫描结果：每次设备列表变化就 bump 一下 tick，
        // 触发 SwiftUI 重新求值 discoveredDevices
        if discoveryCancellable == nil {
            discoveryCancellable = discovery.$devices
                .receive(on: DispatchQueue.main)
                .sink { [weak self] devices in
                    self?.discoveryTick &+= 1
                    // ★ 第二十三轮：扫到盒子就自动填进 IP 框。
                    //   用户反馈「刚开启时 IP 文本框还是 192.168.1.5」——
                    //   以前那个值是写死的默认值，跟真实网络毫无关系。
                    //   现在：没手动改过 / 没连着 → 自动用扫到的第一个。
                    guard let self else { return }
                    if let first = devices.first, !self.hasManuallyEditedIP,
                       !self.isConnected {
                        self.boxIP = first.ip
                        self.deviceName = first.name
                        print("[VM] 自动填入扫描到的盒子: \(first.name) @ \(first.ip)")
                    }
                }
        }
    }

    /// 用户是否在输入框里手动改过 IP（改过就不自动覆盖他的输入）
    private var hasManuallyEditedIP = false

    /// 输入框被编辑时调用（ContentView 的 onChange）
    func markIPManuallyEdited() {
        hasManuallyEditedIP = true
    }

    /// ★ 把DeviceDiscovery 包装成 @Published，
    ///   这样 SwiftUI 才会因为「扫描到新设备」而刷新界面。
    private let discovery = DeviceDiscovery.shared
    @Published private var discoveryTick: Int = 0
    private var discoveryCancellable: AnyCancellable?

    /// 扫描到的设备列表
    var discoveredDevices: [DiscoveredDevice] { discovery.devices }

    /// 手机当前的 IP（界面上显示，方便用户核对是否同一网段）
    var localIP: String { discovery.localIP }

    /// ★ 端到端总延迟（第二十三轮：把采集侧也算进去）
    ///
    /// 之前显示的是 `network.estimatedLatencyMs`（只有网络+盒子），
    /// 少了「声音进麦克风到被 App 拿到」这一段（真机上约 10~25ms），
    /// 所以数字偏小、而且常年不动（因为 RTT 稳定、盒子缓冲被写死）。
    /// ★ 端到端总延迟（第二十四轮：补上「发送积压」这块真正的大头）
    ///
    /// 用户实测「延迟几秒 → 几十秒」，而这里常年显示 145ms 不动 ——
    /// 因为这个数字里从来没有包含**发送侧积压**：
    /// 声音进麦克风后，要在串行发送队列里排队才能真正发出去，
    /// 队列一旦追不上采集，这段等待会**无限增长**（见 AudioEngine 的注释）。
    /// 它才是「几十秒」的主体，必须显示出来，否则指标会持续骗人。
    var totalLatencyMs: Float {
        audio.captureLatencyMs + audio.sendBacklogMs + network.estimatedLatencyMs
    }

    /// 延迟分解，给 UI 的 caption 用
    var latencyBreakdown: (capture: Float, network: Float, box: Float, output: Float) {
        (audio.captureLatencyMs,
         network.roundTripMs / 2,
         network.bufferFillMs,
         20)     // 盒子 AudioTrack 缓冲（960 帧 @48kHz = 20ms）
    }

    /// ★ 发送积压（ms）—— 单独暴露，因为它是最该盯的指标
    ///
    /// 健康时 0~20ms；持续上涨 = 发送追不上采集 = 延迟正在累积。
    var sendBacklogMs: Float { audio.sendBacklogMs }

    /// 因积压超限被丢弃的音频片数（非零 = 发送侧确实追不上，需要看日志）
    var droppedChunkCount: Int { audio.droppedChunkCount }

    /// 选中一个自动发现的盒子
    func selectDevice(_ device: DiscoveredDevice) {
        boxIP = device.ip
        deviceName = device.name
    }

    // MARK: - 连接

    /// 连接到指定 IP 的盒子。
    ///
    /// ★ 修复（2026-10-09）：原来 `boxIP` 参数**完全没被使用** ——
    ///   函数体里直接调`network.connect()`，用的是 init 时写死的
    ///   `192.168.1.5`。所以用户在输入框里改 IP 是**完全无效的**：
    ///   报错信息里显示的还是旧 IP（用户实测发现）。
    ///
    ///   NetworkController 的 host 是 `let`，改 IP 必须重建实例。
    func connect(boxIP: String) {
        let target = boxIP.trimmingCharacters(in: .whitespacesAndNewlines)

        // ★ 记住这次的 IP：下次打开 App 直接用，不用等扫描也不用重填。
        //   （盒子 IP 由 DHCP 分配会变，但大多数时候是稳定的）
        UserDefaults.standard.set(target, forKey: "lastBoxIP")

        // IP 没变 → 直接复用现有连接
        if target == network.hostValue && network.state != .idle {
            network.connect()
            return
        }

        // IP 变了 → 先彻底停掉旧连接，再重建 network + audio
        audio.stop()
        network.disconnect()

        let net = NetworkController(host: target)
        self.network = net
        // AudioEngineController 持有的是旧 network 引用，必须一起换
        self.audio = AudioEngineController(network: net)

        // ★★★ 重建后必须立刻把 UI 参数重新灌回去（2026-10-09 第二十二轮）★★★
        //
        // 新 AudioEngineController 里的 SignalChain 用的是 **struct 默认值**
        // （aecEnabled = true、aecStrength = 0.75 ……），
        // 而用户此刻在 UI 上做的所有调整只存在于 VerifyViewModel 的
        // @Published 属性里，**还没有传给这个新实例**。
        //
        // 后果（用户实测：2026-10-09）：
        //   用户在 UI 上关掉「回声消除 AEC」→ 电视依旧无声。
        //   看起来像「AEC 不是原因」，其实是开关压根没作用到新实例上。
        //
        // 这和之前修过的「改了 IP 但连的还是旧的」是同一类坑：
        // **重建了实例，却忘了把状态迁移过去。**
        apply()

        net.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.applyNetworkState(state)
            }
        }

        net.connect()
    }

    func disconnect() {
        audio.stop()
        // ★ 先发 bye 再断 socket —— 让盒子立刻复位会话，
        //   否则它会一直挂着「手机已连接」直到空闲超时（3 秒）。
        network.sendBye()
        network.disconnect()
        isConnected = false
        isNetworkReady = false
        networkStatusText = NetworkController.State.idle.text
        sentFrames = 0
    }

    /// 等麦克风权限真正落地后再启动引擎。
    ///
    /// ★ 这里为什么必须 async：
    ///   `requestRecordPermission` 是**异步**的，弹窗要等用户点「好」才回调。
    ///   原来在ensure() 里同步调用它、不等结果就立刻 `audio.start()`，
    ///   于是 installTap 在「权限尚未授予」时执行 →
    ///   CoreAudio 直接抛 Objective-C 异常
    ///   `required condition is false: format.sampleRate == 0`
    ///   → Swift 的 do/catch 抓不住 NSException → **闪退**。
    ///   这就是「一点连接就退出」的根因（只在真机复现，模拟器抓不到）。
    private func startAudio() {
        Task { @MainActor in
            let granted = await AVAudioSessionPermission.ensure()
            guard granted else {
                network.disconnect()
                errorMessage = "麦克风权限被拒绝。请到「设置 → 雪宝 K歌麦」里打开。"
                return
            }
            do {
                try audio.start()
                isConnected = true
                errorMessage = nil
            } catch {
                network.disconnect()
                errorMessage = "麦克风启动失败：\(error.localizedDescription)"
            }
        }
    }

    @Published var errorMessage: String? = nil

    // MARK: - 数据同步

    private func syncFromAudio() {
        currentLevelDb = audio.currentLevelDb
        erle = audio.erleDb
        howlingDetected = audio.howlingDetected
        howlingFreqs = audio.howlingFreqs
        isSinging = audio.isSinging
        sentFrames = audio.sentFrames
        sentLevelDb = audio.sentLevelDb
        levelHistory = audio.levelHistory
        if deviceName != network.deviceName {
            deviceName = network.deviceName
        }
    }

    // MARK: - 参数

    private func apply() {
        var p = audio.currentParameters
        p.aecEnabled = aecOn
        p.aecStrength = Float(aecStrength)
        p.howlingSuppressionEnabled = howlOn
        p.howlingStrength = Float(howlStrength)
        p.inputGainDb = Float(inputGain)
        p.reverbWet = Float(reverb)
        p.reverbPreset = reverbPreset
        audio.updateParameters(p)
    }
}

// ══════════════════════════════════════════════════════════════════════
//  权限
// ══════════════════════════════════════════════════════════════════════

enum AVAudioSessionPermission {

    /// 确保麦克风权限已授予，**返回 true 才允许启动音频引擎**。
    ///
    /// - 已授权：立即返回 true
    /// - 未询问：弹系统弹窗，等用户选择后返回其结果（async 挂起，不阻塞音频启动）
    /// - 已拒绝：返回 false，调用方负责提示
    static func ensure() async -> Bool {
        let session = AVAudioSession.sharedInstance()

        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            // 关键：这里必须 await 到回调，拿到真实授权结果再返回。
            // 旧实现 fire-and-forget 后立刻返回 true，导致引擎在无权限下启动 → 闪退。
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}
