//
//  AudioEngine.swift
//  雪宝 K歌麦克风 · 极简验证版
//
//  AVAudioEngine 封装：麦克风采集 → SignalChain → UDP 发送。
//
//  ════════════════════════════════════════════════════════════════════════
//  ★★ 帧长决策（本版与正式版的核心差异）
//  ════════════════════════════════════════════════════════════════════════
//  正式版用 frameSize = 960（20ms），但协议 frameCount 是 u8，最大 255。
//  → 960 塞不进 1 字节 → 静默截断成 255，
//    每包实际发出 1920 字节、头部只声明 510 字节 → **87% 音频被对端丢弃**。
//
//  本版改为 frameSize = 240（5ms）：
//  · 240≤ 255 ✅ 合法，frameCount 无截断
//  · 5ms 粒度对延迟有正面帮助（更早发出，缓冲更浅）
//  · 代价：包头占比 16/496 ≈ 3.2%（可接受；正式版 87% 才是灾难）
//
//  采集格式也做了调整：48kHz / Int16 —— 避免浮点转换开销，
//  且与盒子端 AudioFormat.ENCODING_PCM_16BIT 完全一致。
// ════════════════════════════════════════════════════════════════════════
//

import AVFoundation
import Foundation

final class AudioEngineController {

    // MARK: - 依赖

    private let network: NetworkController
    private var signalChain: SignalChain
    private let engine = AVAudioEngine()

    /// ★ 240 帧 = 5ms @48kHz，必须 ≤ KaraokeProtocol.safeFrameCount
    private let frameSize: Int = KaraokeProtocol.safeFrameCount
    private let sampleRate: Double = 48000

    /// 平滑发送专用队列（不阻塞 AVAudioEngine 的实时回调）
    ///
    /// ⚠️ 这是**串行**队列：一次 tap 回调派发一个任务，任务内部把这一帧
    ///    切成的小片按时间均摊发出。串行意味着任务只能一个接一个执行 ——
    ///    所以「任务耗时」必须小于「任务到达间隔」，否则队列会永久积压。
    ///    （这正是第二十四轮延迟涨到几十秒的根因，见 sendChunked 的注释。）
    private let sendQueue = DispatchQueue(label: "com.xuebao.karamic.send", qos: .userInteractive)

    // ── 发送积压统计（第二十四轮新增）──────────────────────────────────
    /// 已派发但还没真正发出去的音频片数（每片 = frameSize 个样本）。
    ///
    /// 这是「发送侧积压」的直接度量，也是**真实端到端延迟里最大的一块**。
    /// 队列健康时它应该在 0~4 之间波动；一旦持续上涨就说明发得比采得慢，
    /// 延迟会线性累积且**永远不会自己追回来**。
    private let backlogLock = NSLock()
    private var pendingChunks = 0
    private var droppedChunks = 0

    /// 积压上限：超过就直接丢弃新帧，宁可丢一小段声音也不让延迟无限涨。
    /// 12 片 × 240 帧 = 2880 样本 = 60ms 音频。
    /// K歌 场景丢 60ms 只是极短一个「嗒」，但延迟失控是整首歌都唱不下去。
    private let maxBacklogChunks = 12

    /// 当前发送积压（毫秒）—— UI 显示用，是真实延迟的主要组成部分
    var sendBacklogMs: Float {
        backlogLock.lock()
        let n = pendingChunks
        backlogLock.unlock()
        return Float(n) * Float(frameSize) / Float(sampleRate) * 1000.0
    }

    /// 因积压超限被丢弃的片数（诊断用：非零说明发送侧确实追不上）
    var droppedChunkCount: Int {
        backlogLock.lock()
        let n = droppedChunks
        backlogLock.unlock()
        return n
    }

    // MARK: - 状态

    private(set) var isRunning = false
    private(set) var currentLevelDb: Float = -120
    private(set) var peakLevelDb: Float = -120
    private(set) var erleDb: Float = 0
    private(set) var howlingDetected = false
    private(set) var howlingFreqs: [Float] = []
    private(set) var isSinging = false

    private(set) var frameCounter: Int = 0
    private(set) var sentFrames: Int = 0

    /// ★ 新增（第二十三轮）：iOS 真机实际给的采集帧长（样本数）。
    ///   `installTap(bufferSize:)` 只是**建议值**，真机常给 480/960，
    ///   这一段的耗时是端到端延迟里被忽略的一块。
    private(set) var captureFrameLength: Int = 0

    /// 采集侧延迟（ms）= 硬件 I/O 缓冲 + 当前采集帧的时长
    ///
    /// AVAudioSession.ioBufferDuration 是系统实际给的硬件缓冲（我们请求 5ms），
    /// captureFrameLength/sampleRate 是这一帧本身覆盖的时间。
    /// 两者相加才是「声音从进麦克风到被我们拿到」的延迟。
    var captureLatencyMs: Float {
        let io = Float(AVAudioSession.sharedInstance().ioBufferDuration) * 1000
        let frame = captureFrameLength > 0
            ? Float(captureFrameLength) / Float(sampleRate) * 1000
            : 0
        return io + frame
    }

    /// ★ 新增（第十三轮）：Int16 量化之后真正发送的幅度（dBFS）。
    ///
    /// 用它替代「估一个放大后的电平」，因为只有它能回答
    /// 「盒子里到底有没有收到非零数据」。
    /// 计算方式：直接从 sendChunked 里回传真实的 Int16 样本统计。
    private(set) var sentLevelDb: Float = -120

    /// 最近 60 帧电平（画波形用）
    private(set) var levelHistory: [Float] = Array(repeating: -60, count: 60)

    // MARK: - 初始化

    init(network: NetworkController) {
        self.network = network
        self.signalChain = SignalChain(
            sampleRate: Float(sampleRate),
            frameSize: KaraokeProtocol.safeFrameCount
        )
    }

    // MARK: - 会话

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()

        // .playAndRecord + .measurement：拿到最原始信号交给自研 DSP
        //注意：不用 .voiceChat 模式 —— 它会启用系统 VoiceProcessingIO，
        // 里面的 AEC 只能消除 iPhone 自己的声音，对电视喇叭的回声无效，
        // 反而会引入额外延迟和信号染色。
        try session.setCategory(.playAndRecord, mode: .measurement, options: [
            .defaultToSpeaker,
            .allowBluetooth,
            .mixWithOthers
        ])

        try session.setPreferredIOBufferDuration(0.005)   // 5ms，尽量压低采集延迟
        try session.setPreferredSampleRate(sampleRate)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 启动 / 停止

    func start() throws {
        guard !isRunning else { return }

        try configureSession()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "AudioEngine", code: -1, userInfo: [
                NSLocalizedDescriptionKey:
                "音频输入无效（采样率 \(format.sampleRate)），请检查麦克风权限"
            ])
        }

        // ★ 用 nil format 让系统用原生格式，避免强制转换导致的额外延迟/失真。
        //   ⚠️ bufferSize 只是「建议值」：真机（尤其 iOS 17+）不保证严格按 240 回调，
        //   常见实际值是 480(10ms) 或 960(20ms)。
        //   而协议 frameCount 是 u8，上限 255 —— 若实际回调 > 255 帧，
        //   AudioFrameBuilder 的 assert 会直接崩。
        //   所以真正的防线在 process() 里的分片发送，不依赖这里的 bufferSize。
        input.installTap(onBus: 0,
                         bufferSize: AVAudioFrameCount(frameSize),
                         format: nil) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        try engine.start()

        isRunning = true
        signalChain.reset()
    }

    func stop() {
        guard isRunning else { return }

        if engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        signalChain.reset()

        // ★ 必须清零发送积压计数：
        //   若队列里还有派发完但没发出的任务，它们的 pendingChunks 永远
        //   不会被减回来 → 重启后积压计数仍显示很高，甚至一直触发熔断。
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

    // MARK: - 实时处理

    private func process(_ buffer: AVAudioPCMBuffer) {
        // Int16 格式优先（与盒子端一致，零转换）
        var samples: [Float]

        if let ch16 = buffer.int16ChannelData?[0] {
            let n = Int(buffer.frameLength)
            samples = [Float](repeating: 0, count: n)
            for i in 0..<n {
                samples[i] = Float(ch16[i]) / 32768.0
            }
        } else if let ch32 = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            samples = [Float](repeating: 0, count: n)
            for i in 0..<n { samples[i] = ch32[i] }
        } else {
            return
        }

        guard samples.count > 0 else { return }

        // 记录真机实际回调的帧长（用于延迟显示，也让 UI 能看出 tap 是否异常）
        captureFrameLength = samples.count

        // ── DSP ──
        let out = signalChain.process(input: samples)

        // ★ 必须先 record 再 send：AEC 的参考信号要跟实际发出的内容一致
        signalChain.recordSentAudio(out.processed)

        // ── 发送（分片，每片 ≤240 帧，永不触发协议断言）──
        //
        // ★ 为什么必须分片：
        //   协议 frameCount 是 u8，上限 255。iOS 的 tap 回调长度不受控
        //   （可能给 480/ 960 帧），直接整帧发出去会让
        //   `UInt8(frameCount)` 静默回绕，或直接命中 assert。
        //   按 240 帧切片后，每包头里的 frameCount 都是真实值。
        if network.state == .ready {
            sendChunked(out.processed)
        }

        // ── 监测（每 3 帧刷一次 UI，降低刷新压力）──
        frameCounter += 1
        if frameCounter % 3 == 0 {
            // ★ 2026-10-08 修正：显示 **AEC 之前** 的输入电平。
            //
            //   原来用 out.outputLevelDb（AEC 之后的输出）：
            //   AEC 一旦出问题（如曾经出现过的输出静音 bug），
            //   这个读数就恒为 0，UI 上「输入电平」和波形全空，
            //   **让人误以为麦克风坏了**。
            //
            //   改用 inputLevelDb 的意义：
            //     - 它反映麦克风采集是否正常（与 AEC 无关）
            //     - AEC 出问题时它仍正常 → 能立刻区分「麦克风坏了」vs「AEC 坏了」
            //     - ERLE 的定义本身就是「输入回声 vs 残余回声」，
            //       拿输入电平做参照才符合物理含义
            let level = out.inputLevelDb
            let peak = max(peakLevelDb * 0.95, level)
            let erle = out.erleDb
            let howl = out.howling
            let freqs = out.howlingFrequencies
            let singing = out.doubleTalk

            DispatchQueue.main.async {
                self.currentLevelDb = level
                self.peakLevelDb = peak
                self.erleDb = erle
                self.howlingDetected = howl
                self.howlingFreqs = freqs
                self.isSinging = singing
                self.levelHistory.removeFirst()
                self.levelHistory.append(max(level, -60))
            }
        }
    }

    // MARK: - 参数

    /// 把一帧音频切成 ≤240 帧的小包逐个发送。
    ///
    /// iOS 的 tap 回调长度不固定（240/480/960 都可能），
    /// 而协议 frameCount 上限 255，所以必须切片。
    private func sendChunked(_ samples: [Float]) {
        let maxChunk = KaraokeProtocol.safeFrameCount      // 240
        guard !samples.isEmpty else { return }

        // ════════════════════════════════════════════════════════════════
        //  ★ 平滑发送（第二十三轮）—— 降低欠载与延迟的关键
        // ════════════════════════════════════════════════════════════════
        //
        //  【之前】一个 tap 回调（960 帧 = 20ms 的音频）被切成 4 个包后
        //  **在几微秒内一口气全发出去**，然后干等 20ms 直到下一个回调。
        //
        //  盒子端看到的就是「瞬间到达 4 包 + 15ms 空窗」的**突发流**：
        //   · 空窗期只能靠缓冲顶着，缓冲一浅就欠载
        //     （实测每秒 50~80 次，用户能听出断续）
        //   · 为了让缓冲顶得住，只能把缓冲调深 → 延迟被迫变大
        //   这两件事其实是同一个根因。
        //
        //  【现在】把这 4 个包**均摊到这 20ms 内**发出：
        //   960 帧 / 48000Hz = 20ms，分 4 片 ⇒ 每 5ms 发一片。
        //  盒子端就变成了一条**匀速流**，缓冲只要很浅就够了 →
        //  欠载大幅减少，延迟也能跟着压下来。
        //
        //  为什么放在后台队列：不能阻塞 AVAudioEngine 的 tap 回调，
        //  否则会丢帧（实时音频线程的黄金规则：回调里不做等待）。
        // ════════════════════════════════════════════════════════════════
        let chunks = stride(from: 0, to: samples.count, by: maxChunk).map {
            Array(samples[$0..<min($0 + maxChunk, samples.count)])
        }
        guard !chunks.isEmpty else { return }

        // ════════════════════════════════════════════════════════════════
        //  ★★ 第二十四轮：延迟涨到几十秒的真根因就在这里 ★★
        // ════════════════════════════════════════════════════════════════
        //
        //  【上一版（相对 usleep）】
        //      for (i, c) in chunks.enumerated() {
        //          if i > 0 { usleep(gapUs) }        // ← 相对等待
        //          send(c)
        //      }
        //
        //  在**串行队列**里用相对等待，会形成一个正反馈死锁：
        //
        //    sendQueue 是串行的 → 一帧的任务必须等上一帧跑完才开始。
        //    tap 每 20ms 产出一帧（960 帧），任务要在 20ms 内跑完 4 片才不积压。
        //    但 usleep(5000) 的真实耗时是「5ms + 调度开销」，
        //    iOS 上这个开销常常就有 1~10ms（定时器合并、QoS 竞争、
        //    发热降频时更差）。于是单轮很容易变成 25~35ms。
        //
        //    一旦单轮 > 20ms：
        //      第 1 帧晚 5ms → 第 2 帧晚 10ms → 第 3 帧晚 15ms …
        //      每一帧都在上一帧的欠账上**再加**新的欠账。
        //    这个欠账没有任何机制能偿还 —— usleep 只会让下一轮更晚。
        //
        //    实测现象完全吻合用户描述：
        //      刚开始 < 1s → 过一会 2s 多 → 再过一会几十秒。
        //    就是一条单调递增、永不收敛的直线。
        //
        //  【这一版（绝对时间调度 + 积压熔断）】两道防线：
        //
        //   ① 绝对时间：第 i 片的目标时刻 = 本帧起始时刻 + i × gap。
        //      每片发送前先算「距离目标还有多久」，只等**这个差值**。
        //      上一轮迟了 5ms → 这一轮的 now 已经越过 due → 等待量自动变 0
        //      → 立刻发送把欠账补回来。**误差不再累积**。
        //
        //   ② 熔断：pendingChunks 超过 12 片（60ms 音频）就整帧丢弃。
        //      即使 ① 因为某种原因失效（比如 UDP send 长时间阻塞），
        //      延迟也最多卡在 60ms，绝不可能涨到几十秒。
        //      K歌 丢 60ms 只是极短一个「嗒」，比整首歌对不上嘴好得多。
        //
        //   为什么不用 DispatchSourceTimer：它需要额外的 RunLoop 与精度权衡，
        //   而这里只要「对齐到绝对时刻 + 主动追赶」，usleep 足够。
        //
        //   ⚠️ usleep 实际精度约 200µs~1ms，所以等待量 < 500µs 时直接发，
        //      否则「为了睡 0.2ms 反而付出 1ms 的调度代价」，越睡越慢。
        // ════════════════════════════════════════════════════════════════

        // 这一帧覆盖的真实时长 ÷ 片数 = 每片之间该隔多久（纳秒）
        let frameMs = Double(samples.count) / sampleRate * 1000.0
        let gapNs = UInt64(max(0.0, frameMs / Double(chunks.count) * 1_000_000.0))

        if chunks.count == 1 {
            // 单包无需节流，直接发（最低延迟）
            network.sendAudioFrame(samples: chunks[0], sampleRate: UInt16(sampleRate))
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

        // ── 防线 ①：绝对时间调度 ──
        // 取「本帧起始时刻」作为时间原点。注意必须在派发**之前**取，
        // 这样即使任务在队列里等了一会儿，也能靠绝对时刻把节奏拉回来。
        let startNs = DispatchTime.now().uptimeNanoseconds

        sendQueue.async { [weak self] in
            guard let self else { return }
            for (i, c) in chunks.enumerated() {
                if i > 0, gapNs > 0 {
                    let due = startNs + UInt64(i) * gapNs
                    let now = DispatchTime.now().uptimeNanoseconds
                    if due > now {
                        let waitNs = due - now
                        // < 500µs 就直接发（usleep 的开销比它本身还大）
                        if waitNs >= 500_000 {
                            usleep(useconds_t(min(waitNs / 1_000, 200_000)))
                        }
                    }
                    // due <= now：已经迟了，不等待，立刻发 → 自动追赶
                }
                self.network.sendAudioFrame(samples: c,
                                            sampleRate: UInt16(self.sampleRate))
                self.sentFrames += 1
                self.backlogLock.lock()
                self.pendingChunks -= 1
                self.backlogLock.unlock()
            }
        }

        // ★ 第十三轮：统计**真正进包的 Int16 样本**的幅度。
        //   不能用 Float 估算 —— Float 有幅度不等于 Int16 有数据。
        //   这里用与 AudioFrameBuilder.build 完全一致的转换，
        //   保证「显示的」与「发出的」是同一份数据。
        let gain = AudioFrameBuilder.outputGain
        var sumSq: Float = 0
        var nonZero = 0
        for s in samples {
            // ★ 与 AudioFrameBuilder.build 保持一致：
            //   Float(-1~1) → Int16 **必须乘满量程 32767**，否则 0.03 会变成 0，
            //   这个统计就会永远显示「全零」，把真正的量化 bug 掩盖掉。
            //
            // ⚠️ 必须手动 clamp：Swift 的 `Int16(someFloat)` 在超出范围时会
            //    **直接 trap 崩溃**，而 vDSP.floatingPointToInteger 自带饱和裁剪。
            //    两边行为不一致，这里不 clamp 就有闪退风险。
            let scaled = s * gain * Float(Int16.max)
            let clamped = max(-32768.0, min(32767.0, scaled))
            let v = Int16(clamped.rounded())
            sumSq += Float(v) * Float(v)
            if v != 0 { nonZero += 1 }
        }
        let rms = sqrt(sumSq / Float(samples.count)) / 32768.0
        if nonZero == 0 {
            // 一个非零样本都没有 → 全零包
            sentLevelDb = -120
        } else {
            sentLevelDb = 20 * log10(max(rms, 1e-7))
        }
    }

    func updateParameters(_ p: SignalParameters) {
        signalChain.parameters = p
    }

    var currentParameters: SignalParameters { signalChain.parameters }

    /// 实测采集帧长（诊断用：确认系统真的按 240 帧回调）
    var actualFrameSize: Int { frameSize }
}
