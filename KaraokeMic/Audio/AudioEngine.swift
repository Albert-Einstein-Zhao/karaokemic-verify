//
//  AudioEngine.swift
//  雪宝 K歌麦克风 · iOS 端
//
//  AVAudioEngine 封装：麦克风采集 → SignalChain 处理 → UDP 发送。
//
//  ════════════════════════════════════════════════════════════════════════
//  ⚠️ 关于 iOS 系统自带的 VoiceProcessingIO（回声消除）
//  ════════════════════════════════════════════════════════════════════════
//  它确实自带 AEC，但**对我们这个场景基本没用**：
//    系统的 AEC 只能消除「iPhone 自己扬声器发出的声音」被麦克风拾到的回声。
//    而你的回声来自**电视机的喇叭** —— 系统完全不知道那段声音的存在，
//    拿不到参考信号，AEC 无从下手。
//
//  所以本项目**不启用** VoiceProcessingIO，改用自己实现的
//  AdaptiveEchoCanceller（用「我们刚发出的 PCM」当参考信号 —— 这个我们确实有）。
//
//  代价：无法消除 K歌 App 的伴奏漏回。缓解手段是啸叫抑制 + 增益管控 + 物理隔离。
//═══════════════════════════════════════════════════════════════════════════

import AVFoundation
import Foundation

/// 音频引擎控制器。
final class AudioEngineController {

    // MARK: - 依赖

    private let network: NetworkController
    private var signalChain: SignalChain
    private let engine = AVAudioEngine()

    private let sampleRate: Double = 48000
    // ★ 帧长必须是 255 帧以内（协议帧头 frameCount 字段是 u8），取 240 = 5ms @48kHz。
    //   曾经这里是 960（20ms），配合 Protocol.swift 里的 min(frameCount, 255)
    //   静默截断，导致 73% 的音频数据被 Android 端丢弃。详见 Protocol.swift 注释。
    private let frameSize: Int = 240

    // ══════════════════════════════════════════════════════════════════
    //  发送节流（2026-10-09 从验证版同步）
    // ══════════════════════════════════════════════════════════════════
    //
    //  串行队列：一次 tap 回调派发一个任务，任务内部把这一帧切成的小片
    //  按时间均摊发出。串行意味着「任务耗时」必须小于「任务到达间隔」，
    //  否则队列会**永久积压** —— 这正是验证版实测
    //  「延迟 1s → 2s → 几十秒」的根因。
    //
    //  所以这里配了两道防线：绝对时间调度（误差不累积）+ 积压熔断（硬上限）。
    //  详见 sendChunked 里的注释。
    private let sendQueue = DispatchQueue(
        label: "com.xuebao.karamic.send", qos: .userInteractive
    )

    /// 已派发但还没真正发出去的音频片数（每片 = frameSize 个样本）。
    private let backlogLock = NSLock()
    private var pendingChunks = 0
    private var droppedChunks = 0

    /// 积压上限：超过就整帧丢弃。12 片 × 240 帧 = 60ms 音频。
    private let maxBacklogChunks = 12

    /// 当前发送积压（毫秒）—— 真实端到端延迟的主要组成部分
    var sendBacklogMs: Float {
        backlogLock.lock()
        let n = pendingChunks
        backlogLock.unlock()
        return Float(n) * Float(frameSize) / Float(sampleRate) * 1000.0
    }

    /// 因积压超限被丢弃的片数（诊断用）
    var droppedChunkCount: Int {
        backlogLock.lock()
        let n = droppedChunks
        backlogLock.unlock()
        return n
    }

    // MARK: - 状态

    private(set) var isRunning = false

    /// 实时监测数据（UI 读取）
    private(set) var currentLevelDb: Float = -120
    private(set) var peakLevelDb: Float = -120
    private(set) var erleDb: Float = 0
    private(set) var howlingDetected = false
    private(set) var howlingFrequencies: [Float] = []
    private(set) var isSinging = false        // 双讲检测 → 用户是否在唱
    private(set) var sampleCount: Int = 0

    /// 已发送的音频包数量（分片后可能一帧对应多个包）。
    private(set) var sentFrames: Int = 0

    /// 音频电平历史（用于 UI 波形图），保留最近 60 个值
    private var levelHistory: [Float] = Array(repeating: -60, count: 60)

    // MARK: - 初始化

    init(network: NetworkController) {
        self.network = network
        self.signalChain = SignalChain(sampleRate: Float(sampleRate), frameSize: frameSize)
    }

    // MARK: - 会话配置

    /// 配置音频会话。
    /// - `.playAndRecord`：既采集又播放（用于本机监听回放）
    /// - `.measurement`：关闭系统 AGC/NS/AGC，拿到最原始的信号交给我们的 DSP
    /// - `.defaultToSpeaker`：不插耳机时默认外放
    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()

        try session.setCategory(.playAndRecord, mode: .measurement, options: [
            .defaultToSpeaker,      // 默认外放
            .allowBluetooth,        // 允许蓝牙耳机（用户想戴耳机监听时）
            .mixWithOthers          // 允许与音乐 App 混音
        ])

        // 期望时长 .playAndRecord = 10ms，这是 iOS 能给的最小值
        try session.setPreferredIOBufferDuration(0.010)
        try session.setPreferredSampleRate(sampleRate)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 启动 / 停止

    /// 启动音频采集与传输。
    func start() throws {
        guard !isRunning else { return }

        try configureSession()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // 校验音频格式（真机上 format 可能是 0Hz，尚未激活）
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "AudioEngine", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "音频输入格式无效（sampleRate=\(inputFormat.sampleRate)），请检查麦克风权限"
            ])
        }

        // 安装 tap：bufferSize 设为 frameSize 获得稳定节奏
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(frameSize),
                            format: inputFormat) { [weak self] buffer, time in
            self?.processBuffer(buffer)
        }

        // 准备并启动引擎
        engine.prepare()
        try engine.start()

        isRunning = true
        signalChain.reset()
    }

    /// 停止音频采集。
    func stop() {
        guard isRunning else { return }

        if engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()

        signalChain.reset()

        // ★ 必须清零发送积压计数：
        //   若队列里还有派发完但没发出的任务，它们的 pendingChunks 永远
        //   不会被减回来 → 重启后积压计数仍很高，甚至一直触发熔断。
        backlogLock.lock()
        pendingChunks = 0
        droppedChunks = 0
        backlogLock.unlock()

        isRunning = false
        currentLevelDb = -120
        erleDb = 0
        howlingDetected = false
        isSinging = false

        try? AVAudioSession.sharedInstance().setActive(false,
                                                         options: .notifyOthersOnDeactivation)
    }

    // MARK: - 音频处理（实时线程）

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        // 转成Array（SignalChain 的接口用 Array）
        var samples = [Float](repeating: 0, count: frameLength)
        for i in 0..<frameLength {
            samples[i] = channelData[i]
        }

        // ── DSP 处理链 ──
        let output = signalChain.process(input: samples)

        // ── 记录已发送音频，供下一帧做 AEC 参考 ──
        // ⚠️ 必须先 record 再 send，保证参考信号与实际发出的内容一致
        signalChain.recordSentAudio(output.processed)

        // ── 发送（分片，每片 ≤240 帧，永不触发协议断言）──
        //
        // ★ iOS 的 tap 回调长度不受控（bufferSize 只是建议值，真机常给 480/960），
        //   而协议 frameCount 是 u8、上限 255。整帧直发会命中 assert 或静默回绕。
        if network.state == .ready {
            sendChunked(output.processed)
        }

        // ── 更新监测数据（每 5 帧更新一次UI，降低 UI 刷新压力） ──
        sampleCount += 1
        if sampleCount % 5 == 0 {
            DispatchQueue.main.async {
                self.currentLevelDb = output.outputLevelDb
                self.peakLevelDb = max(self.peakLevelDb * 0.95, output.outputLevelDb)
                self.erleDb = output.erleDb
                self.howlingDetected = output.howling
                self.howlingFrequencies = output.howlingFrequencies
                self.isSinging = output.doubleTalk

                // 追加到历史（用于波形图）
                self.levelHistory.removeFirst()
                self.levelHistory.append(max(output.outputLevelDb, -60))
            }
        }
    }

    // MARK: - 参数控制

    /// 把一帧音频切成 ≤240 帧的小包逐个发送。
    ///
    /// iOS 的 tap 回调长度不固定（240/480/960 都可能），
    /// 而协议 frameCount 上限 255，所以必须切片。
    private func sendChunked(_ samples: [Float]) {
        let maxChunk = KaraokeProtocol.safeFrameCount      // 240
        guard !samples.isEmpty else { return }

        var offset = 0
        var chunks: [[Float]] = []
        while offset < samples.count {
            let end = min(offset + maxChunk, samples.count)
            chunks.append(Array(samples[offset..<end]))
            offset = end
        }
        guard !chunks.isEmpty else { return }

        // ══════════════════════════════════════════════════════════════
        //  ★★ 发送节流：绝对时间调度 + 积压熔断 ★★
        // ══════════════════════════════════════════════════════════════
        //
        //  【为什么不能在实时回调里一口气全发】
        //  tap 回调长度不受控（请求 240 帧，真机常给 480/960），
        //  一帧切成 2~4 片后若在几微秒内全发出去，
        //  盒子端看到的就是「瞬间 4 包 + 15ms 空窗」的突发流：
        //  空窗期只能靠缓冲顶着，缓冲一浅就欠载爆音。
        //
        //  【为什么不能用相对 usleep 做节流 —— 验证版踩过的坑】
        //      for (i, c) in chunks.enumerated() {
        //          if i > 0 { usleep(gapUs) }        // ← 相对等待
        //          send(c)
        //      }
        //  在**串行队列**里，usleep(5000) 的真实耗时是「5ms + 调度开销」，
        //  iOS 上这个开销常有 1~10ms（定时器合并、QoS 竞争、发热降频）。
        //  单轮一旦超过采集间隔，欠账就会**逐帧叠加且永不偿还** ——
        //  验证版实测就是「刚开始 <1s → 2s → 几十秒」的单调直线。
        //
        //  【这一版的两道防线】
        //   ① 绝对时间：第 i 片的目标时刻 = 本帧起始 + i × gap，
        //      每片只等「距离目标的差值」。上一轮迟了 → 这一轮等待量自动变 0
        //      → 立刻发送把欠账补回来，**误差不累积**。
        //   ② 熔断：pendingChunks 超过 12 片（60ms）就整帧丢弃。
        //      即使 ① 失效（比如 UDP send 长时间阻塞），
        //      延迟也最多卡在 60ms，绝不可能涨到几十秒。
        //      K歌 丢 60ms 只是极短一个「嗒」，比整首歌对不上嘴好得多。
        //
        //  ⚠️ usleep 实际精度约 200µs~1ms，等待量 < 500µs 时直接发，
        //     否则「为了睡 0.2ms 反而付出 1ms 的调度代价」，越睡越慢。
        // ══════════════════════════════════════════════════════════════

        if chunks.count == 1 {
            // 单包无需节流，直接发（最低延迟）
            network.sendAudioFrame(samples: chunks[0], sampleRate: UInt32(sampleRate))
            sentFrames += 1
            return
        }

        // ── 防线 ②：积压熔断 ──
        backlogLock.lock()
        if pendingChunks > maxBacklogChunks {
            droppedChunks += chunks.count
            backlogLock.unlock()
            return
        }
        pendingChunks += chunks.count
        backlogLock.unlock()

        // 本帧覆盖的真实时长 ÷ 片数 = 每片之间该隔多久（纳秒）
        let frameMs = Double(samples.count) / sampleRate * 1000.0
        let gapNs = UInt64(max(0.0, frameMs / Double(chunks.count) * 1_000_000.0))

        // ── 防线 ①：绝对时间调度 ──
        // 时间原点必须在派发**之前**取，这样即使任务在队列里等了一会儿，
        // 也能靠绝对时刻把节奏拉回来。
        let startNs = DispatchTime.now().uptimeNanoseconds

        sendQueue.async { [weak self] in
            guard let self else { return }
            for (i, c) in chunks.enumerated() {
                if i > 0, gapNs > 0 {
                    let due = startNs + UInt64(i) * gapNs
                    let now = DispatchTime.now().uptimeNanoseconds
                    if due > now {
                        let waitNs = due - now
                        if waitNs >= 500_000 {
                            usleep(useconds_t(min(waitNs / 1_000, 200_000)))
                        }
                    }
                    // due <= now：已经迟了，不等待，立刻发 → 自动追赶
                }
                self.network.sendAudioFrame(samples: c, sampleRate: UInt32(self.sampleRate))
                self.sentFrames += 1
                self.backlogLock.lock()
                self.pendingChunks -= 1
                self.backlogLock.unlock()
            }
        }
    }

    /// 更新处理参数。
    func updateParameters(_ params: SignalParameters) {
        signalChain.parameters = params
    }

    var currentParameters: SignalParameters {
        signalChain.parameters
    }

    /// 电平历史（UI 波形图用）。
    var levels: [Float] { levelHistory }

    /// 端到端延迟估算。
    /// 公式：网络单程 + 盒子播放缓冲 + 盒子输出延迟(~20ms)
    var estimatedLatencyMs: Float {
        (network.roundTripMs / 2) + network.bufferFillMs + 20
    }
}
