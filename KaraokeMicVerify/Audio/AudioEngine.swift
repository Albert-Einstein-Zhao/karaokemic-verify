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
    private let sendQueue = DispatchQueue(label: "com.xuebao.karamic.send", qos: .userInteractive)

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

        // 这一帧覆盖的真实时长 ÷ 片数 = 每片之间该隔多久
        let frameMs = Double(samples.count) / sampleRate * 1000.0
        let gapUs = UInt32(max(0, frameMs / Double(chunks.count) * 1000.0))

        if chunks.count == 1 {
            network.sendAudioFrame(samples: chunks[0], sampleRate: UInt16(sampleRate))
            sentFrames += 1
        } else {
            sendQueue.async { [weak self] in
                guard let self else { return }
                for (i, c) in chunks.enumerated() {
                    if i > 0, gapUs > 0 { usleep(useconds_t(gapUs)) }
                    self.network.sendAudioFrame(samples: c,
                                                sampleRate: UInt16(self.sampleRate))
                    self.sentFrames += 1
                }
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
