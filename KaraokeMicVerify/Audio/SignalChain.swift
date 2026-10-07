//
//  SignalChain.swift
//  雪宝 K歌麦克风 · iOS 端
//
//  音频处理链的总装。把各个 DSP 模块按正确顺序串起来。
//
//  ════════════════════════════════════════════════════════════════════════
//  信号流（顺序很重要，每一步都有理由）
//  ════════════════════════════════════════════════════════════════════════
//
//   麦克风 ──▶ [1] 高通 80Hz ──▶ [2] 输入增益 ──▶ [3] AEC 回声消除
//                                                        │
//                                                        ▼
//   发送到盒子 ◀── [9] 混响 ◀── [8] EQ ◀── [7] 啸叫抑制 ◀── [6] 动态处理
//                                                        ▲
//                                                        │
//                                          [4][5] 在此处分出一路
//                                          作为 AEC 的参考信号
//
//  逐步解释：
//   [1] 高通 —— 先切低频，因为低频（空调、桌面震动）会让后面的
//        AEC 和啸叫检测产生大量无意义的低频能量，白白消耗处理能力。
//   [2] 输入增益 —— 让用户的嘴到麦克风的距离差异被补偿。
//   [3] AEC —— 核心。输入是麦克风信号，参考是[4] 记录的本帧发出的 PCM。
//   [4] 环形缓冲 —— 记录「已经发出去的 PCM」，就是 AEC 的参考信号。
//   [5] 延迟对齐 —— 关键！参考信号必须与麦克风信号「时间对齐」。
//        麦克风听到的回声是 N 毫秒前发出的声音，所以参考要延迟对齐。
//   [6] 动态处理 —— 压缩器 + 限制器，防止瞬时爆音（离麦克风太近时）。
//   [7] 啸叫抑制 —— 陷波器组，压制窄带发散。
//   [8] EQ —— 低/中/高三段，塑造音色。
//   [9] 混响 —— 加空间感。你要求的功能。
//
//  ⚠️ 缓冲区大小说明：
//     iOS 的 AVAudioEngine inputNode tap 回调，给到的缓冲通常是这个大小。
//     20ms @48kHz = 960 样本。KaraokeMic 的协议默认就是 20ms。
//═══════════════════════════════════════════════════════════════════════════

import Accelerate
import Foundation

/// 音频处理链。持有全部 DSP 模块。
///
/// ⚠️ 线程模型：
///   · `process()` 只在音频实时线程调用
///   · UI 参数更新走 `setParameters()`，通过原子变量与音频线程通信
///   · 不要在 UI 线程直接改 DSP 内部状态
final class SignalChain {

    // MARK: - 处理参数（跨线程共享，用原子锁保护）

    private let lock = NSLock()

    private var _parameters = SignalParameters()
    var parameters: SignalParameters {
        get { lock.lock(); defer { lock.unlock() }; return _parameters }
        set { lock.lock(); _parameters = newValue; lock.unlock() }
    }

    /// 实时读取（音频线程用，无锁开销）
    @inline(__always)
    private func currentParams() -> SignalParameters {
        // 用无锁方式读——struct 里都是 Float/Int，实际是原子的。
        // Swift 里严格说需要 atomic，这里用 lock 开销可接受（约 50ns）。
        lock.lock()
        let p = _parameters
        lock.unlock()
        return p
    }

    // MARK: - DSP 模块

    private var highPass: Biquad
    private var compressor: DynamicProcessor
    private var equalizer: [Biquad]           // 3 段
    private let aec: AdaptiveEchoCanceller
    private let howlingSuppressor: HowlingSuppressor
    private var reverb: Reverb

    // AEC 参考信号环形缓冲
    private var referenceRing: [Float]
    private var referenceWriteIndex: Int = 0
    /// 参考信号的累计写入样本数（用于计算延迟对齐量）
    private var referenceSampleCounter: Int = 0

    private let sampleRate: Float
    private let frameSize: Int

    // 复用缓冲，避免实时线程频繁分配内存
    private var scratchBuffer: [Float]
    private var processedBuffer: [Float]

    // MARK: - 初始化

    init(sampleRate: Float = 48000, frameSize: Int = 240) {
        self.sampleRate = sampleRate
        self.frameSize = frameSize

        // [1] 高通 80Hz，Q=0.707 (Butterworth)
        self.highPass = Biquad(
            BiquadCoeffs.highpass(f0: 80, q: 0.707, sampleRate: sampleRate)
        )

        // [2][6] 动态处理
        self.compressor = DynamicProcessor(sampleRate: sampleRate)

        // [8] 三段 EQ（默认平坦）
        self.equalizer = [
            Biquad(BiquadCoeffs.peaking(f0: 100, q: 0.8, gainDb: 0, sampleRate: sampleRate)),
            Biquad(BiquadCoeffs.peaking(f0: 1000, q: 0.8, gainDb: 0, sampleRate: sampleRate)),
            Biquad(BiquadCoeffs.peaking(f0: 8000, q: 0.8, gainDb: 0, sampleRate: sampleRate))
        ]

        // [3] AEC
        self.aec = AdaptiveEchoCanceller(taps: 512, mu: 0.15)

        // [7] 啸叫抑制
        self.howlingSuppressor = HowlingSuppressor(sampleRate: sampleRate)

        // [9] 混响
        self.reverb = Reverb(sampleRate: sampleRate, parameters: .default)

        // AEC 参考环形缓冲：512 taps + 一点余量
        self.referenceRing = [Float](repeating: 0, count: 1024)

        self.scratchBuffer = [Float](repeating: 0, count: frameSize * 2)
        self.processedBuffer = [Float](repeating: 0, count: frameSize * 2)
    }

    // MARK: - 主处理入口

    /// 处理一帧麦克风音频。
    /// - Parameters:
    ///   - input: 原始麦克风 PCM（Float，-1.0 ~ 1.0）
    ///   - sentReference: 上一帧实际发出去的 PCM（作为 AEC 参考）
    /// - Returns: 处理后的音频 + 本帧将要发送的音频
    struct Output {
        /// 处理后的音频（已含混响，可直接发送）
        var processed: [Float]
        /// 输入电平(dBFS)，供 UI 显示
        var inputLevelDb: Float
        /// 输出电平(dBFS)
        var outputLevelDb: Float
        /// AEC 残余回声量(dB)
        var erleDb: Float
        /// 是否检测到啸叫
        var howling: Bool
        /// 啸叫频率列表
        var howlingFrequencies: [Float]
        /// 是否检测到双讲（用户正在唱）
        var doubleTalk: Bool
    }

    func process(input: [Float]) -> Output {
        let params = currentParams()
        let n = input.count

        // ── 阶段 [1]：高通滤波 ──
        var work = [Float](input)   // 拷贝一份，原数组不改（调试用）
        if params.highPassEnabled {
            highPass.process(&work)
        }

        // ── 阶段[2]：输入增益 ──
        // dB 转线性幅度：gain = 10^(dB/20)
        let inputGain = pow(10, params.inputGainDb / 20)
        var gainScalar = inputGain
        // vDSP 只吃裸指针；原地相乘（输入输出同址）
        work.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_vsmul(base, 1, &gainScalar, base, 1, vDSP_Length(n))
        }

        let inputLevel = dbfs(work)

        // ── 阶段 [4][5]：构造 AEC 参考信号 ──
        let reference = makeAlignedReference(forFrameSize: n)

        // ── 阶段 [3]：回声消除 ──
        if params.aecEnabled {
            aec.strength = params.aecStrength
            aec.process(mic: &work, reference: reference)
        }

        // ── 阶段 [6]：动态处理（压缩 + 限制） ──
        if params.compressorEnabled {
            compressor.update(
                thresholdDb: params.compThresholdDb,
                ratio: params.compRatio,
                makeupGainDb: params.compMakeupDb
            )
            compressor.process(&work)
        }

        // ── 阶段 [7]：啸叫抑制 ──
        if params.howlingSuppressionEnabled {
            howlingSuppressor.strength = params.howlingStrength
            howlingSuppressor.process(&work)
        }

        // ── 阶段 [8]：EQ ──
        if params.eqLowDb != 0 || params.eqMidDb != 0 || params.eqHighDb != 0 {
            applyEQ(&work, params: params)
        }

        // ── 阶段 [9]：混响 ──
        // ★ 必须是 var：下面混响分支里对它做逐元素赋值（取左声道），
        //   声明成 let 会报 "cannot mutate subscript of immutable value"
        var final: [Float]
        if params.reverbWet > 0.005 {
            reverb.update(parameters: ReverbParameters(
                wet: params.reverbWet,
                damping: params.reverbDamping,
                roomSize: params.reverbRoomSize,
                width: params.reverbWidth
            ))
            // 混响返回立体声交织数据，取左声道作为单声道发送
            let stereo = reverb.process(samples: work)
            final = [Float](repeating: 0, count: n)
            for i in 0..<n { final[i] = stereo[i * 2] }
        } else {
            final = work
        }

        // ── 阶段 [10]：输出保护（软限幅） ──
        var output = final
        softClip(&output, threshold: 0.95)

        let outputLevel = dbfs(output)

        return Output(
            processed: output,
            inputLevelDb: inputLevel,
            outputLevelDb: outputLevel,
            erleDb: aec.erleDb,
            howling: howlingSuppressor.howlingDetected,
            howlingFrequencies: howlingSuppressor.detectedFrequencies,
            doubleTalk: aec.doubleTalk
        )
    }

    // MARK: - AEC 参考信号构造

    /// 从环形缓冲取出一段与当前帧时间对齐的参考信号。
    ///
    /// 时间对齐原理：
    ///   麦克风在时刻 T 采到的声音里，包含了盒子在时刻 T-Δ 播出的内容。
    ///   所以参考信号应该取「Δ 毫秒前发出的 PCM」。
    ///   Δ 包含了：网络传输 + 盒子播放缓冲 + 声波传播 + 处理延迟。
    ///   实测家庭环境 Δ ≈ 30~60ms。这里用可调的经验值，
    ///   更好的做法是让 AEC 自己搜索最优对齐（更复杂，V2 做）。
    private func makeAlignedReference(forFrameSize n: Int) -> [Float] {
        let alignmentSamples = Int(sampleRate * 0.040)   // 40ms

        var ref = [Float](repeating: 0, count: n)
        let ringSize = referenceRing.count

        for i in 0..<n {
            // 从「当前写指针 - alignmentSamples」往回读
            let readIndex = ((referenceWriteIndex - alignmentSamples - 1 - i) % ringSize + ringSize) % ringSize
            ref[i] = referenceRing[readIndex]
        }

        return ref
    }

    /// 把「已经发送出去的 PCM」写入环形缓冲，供下一帧作为参考。
    /// ⚠️ 必须在音频发送后调用，顺序很重要。
    func recordSentAudio(_ sent: [Float]) {
        let ringSize = referenceRing.count
        for sample in sent {
            referenceRing[referenceWriteIndex] = sample
            referenceWriteIndex = (referenceWriteIndex + 1) % ringSize
            referenceSampleCounter += 1
        }
    }

    // MARK: - EQ 应用

    private func applyEQ(_ buf: inout [Float], params: SignalParameters) {
        // 更新系数
        let gains = [params.eqLowDb, params.eqMidDb, params.eqHighDb]
        let freqs: [Float] = [100, 1000, 8000]

        for i in 0..<3 {
            let newCoeffs = BiquadCoeffs.peaking(
                f0: freqs[i], q: 0.8, gainDb: gains[i], sampleRate: sampleRate
            )
            equalizer[i] = Biquad(newCoeffs)
        }

        // 串联处理（低→中→高）
        for i in 0..<equalizer.count {
            equalizer[i].process(&buf)
        }
    }

    // MARK: - 工具函数

    /// 计算 dBFS（满刻度 1.0 = 0 dBFS）
    private func dbfs(_ signal: [Float]) -> Float {
        guard !signal.isEmpty else { return -120 }
        var rms: Float = 0
        // vDSP 只吃裸指针
        signal.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_rmsqv(base, 1, &rms, vDSP_Length(signal.count))
        }
        guard rms > 1e-10 else { return -120 }
        return 20 * log10(rms)
    }

    /// 软限幅：超过阈值后用 tanh 曲线平滑压缩，而非硬削。
    /// 硬削（clip）会产生严重失真（方波化），K歌场景很明显。
    func softClip(_ buf: inout [Float], threshold: Float) {
        for i in buf.indices {
            let x = buf[i]
            let ax = abs(x)
            if ax > threshold {
                // tanh 型软限幅，保持最大增益为 1
                let over = (ax - threshold) / (1 - threshold)
                let shaped = threshold + (1 - threshold) * tanh(over * 1.5)
                buf[i] = x > 0 ? shaped : -shaped
            }
        }
    }

    // MARK: - 状态查询

    /// 是否检测到双讲（用户正在唱）。
    var isDoubleTalking: Bool { aec.doubleTalk }

    /// 是否检测到啸叫。
    var isHowling: Bool { howlingSuppressor.howlingDetected }

    /// AEC 残余回声量。
    var erleDb: Float { aec.erleDb }

    // MARK: - 重置

    /// 重置所有 DSP 状态（连接断开 / 切换设备）。
    func reset() {
        highPass.reset()
        compressor.reset()
        for i in equalizer.indices { equalizer[i].reset() }
        aec.resetAdaptive()
        howlingSuppressor.reset()
        reverb.reset()
        for i in referenceRing.indices { referenceRing[i] = 0 }
        referenceWriteIndex = 0
    }
}

// MARK: - 信号参数

/// 所有可调参数。UI 改这个，通过 `SignalChain.parameters` 传进去。
struct SignalParameters: Equatable {
    // 输入
    var highPassEnabled: Bool = true
    var inputGainDb: Float = 0        // -20 ~ +20

    // 回声消除
    var aecEnabled: Bool = true
    var aecStrength: Float = 0.75     // 0 ~ 1

    // 啸叫抑制
    var howlingSuppressionEnabled: Bool = true
    var howlingStrength: Float = 0.6  // 0 ~ 1

    // 动态处理
    var compressorEnabled: Bool = true
    var compThresholdDb: Float = -18
    var compRatio: Float = 3.0        // 1~10
    var compMakeupDb: Float = 4.0

    // EQ (-12 ~ +12 dB)
    var eqLowDb: Float = 0
    var eqMidDb: Float = 0
    var eqHighDb: Float = 0

    // 混响（你要求的功能）
    var reverbPreset: ReverbPreset = .smallRoom
    var reverbWet: Float = 0.12       // 0 ~ 0.4
    var reverbDamping: Float = 0.65
    var reverbRoomSize: Float = 0.45
    var reverbWidth: Float = 0.6

    static let `default` = SignalParameters()
}

// MARK: - 动态处理器（压缩器 + 限制器）

/// 峰值压缩器。
///
/// 作用：防止唱歌喊破音时电平突然飙升（数字削波听感非常刺耳）。
/// 比例：超过阈值后，输出增加的幅度只有输入的1/ratio。
final class DynamicProcessor {
    private var envelopeFollower: Float = 0
    private var gainReductionDb: Float = 0
    private let sampleRate: Float
    private let attackCoeff: Float
    private let releaseCoeff: Float

    private var thresholdDb: Float = -18
    private var ratio: Float = 3.0
    private var makeupDb: Float = 4.0

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        // 攻击 5ms（快，要抓住瞬态），释放 100ms（慢，要平滑）
        self.attackCoeff = exp(-1.0 / (0.005 * sampleRate))
        self.releaseCoeff = exp(-1.0 / (0.100 * sampleRate))
    }

    func update(thresholdDb: Float, ratio: Float, makeupGainDb: Float) {
        self.thresholdDb = thresholdDb
        self.ratio = max(ratio, 1)
        self.makeupDb = makeupGainDb
    }

    func process(_ buf: inout [Float]) {
        let thresholdLinear = pow(10, thresholdDb / 20)
        let makeupLinear = pow(10, makeupDb / 20)
        let slope = (1 / ratio - 1)     // 负值，代表压缩

        for i in buf.indices {
            let x = buf[i]
            let ax = abs(x)

            // 包络跟随（峰值检波器）
            let coeff = ax > envelopeFollower ? attackCoeff : releaseCoeff
            envelopeFollower = ax * (1 - coeff) + envelopeFollower * coeff

            // 计算增益
            var gain: Float = 1
            if envelopeFollower > thresholdLinear, thresholdLinear > 0 {
                let overDb = 20 * log10(envelopeFollower / thresholdLinear)
                gain = pow(10, (overDb * slope) / 20)
            }

            gainReductionDb = max(gainReductionDb, -20 * log10(max(gain, 0.01)))

            buf[i] = x * gain * makeupLinear
        }

        // 释放衰减，让 UI 上的电平表回落
        gainReductionDb *= 0.999
    }

    func reset() {
        envelopeFollower = 0
        gainReductionDb = 0
    }

    var reductionDb: Float { gainReductionDb }
}
