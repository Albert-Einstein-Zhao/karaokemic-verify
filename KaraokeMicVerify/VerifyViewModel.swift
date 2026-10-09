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

    @Published var boxIP: String = "192.168.1.5"
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
                .sink { [weak self] _ in
                    self?.discoveryTick &+= 1
                }
        }
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
