//
//  HowlingSuppressor.swift
//  雪宝 K歌麦克风 · iOS 端
//
//  ════════════════════════════════════════════════════════════════════════
//  啸叫（Howling / Acoustic Feedback）的成因与对策
//  ════════════════════════════════════════════════════════════════════════
//
//  物理过程（正反馈回路）：
//    麦克风拾取 → 放大 → 喇叭播放 → 空气传播 → 再次被麦克风拾取 → ……
//    每一圈能量净增加，某一频率率先发散 → 听到"呜——"的尖锐啸叫
//
//  关键特征（也是本算法的检测依据）：
//    1. **窄带**：能量集中在极窄的频段（人耳听起来很"细"）
//    2. **能量持续攀升**：不是瞬间出现，而是缓慢上升
//    3. **高信噪比**：该频段能量远高于同频段的正常背景
//
//  传统做法是防伪反馈器(Feedback Eliminator)，业界标准算法：
//    ① 持续监测频谱能量
//    ② 找出「持续上升的窄带峰」
//    ③ 在该频率上放置自适应陷波器（Notch Filter）压制它
//
//  本实现：8路并行自适应陷波器 + 频谱趋势检测
//    - 8 路够用：客厅声环境下同时啸叫的频率极少超过 3 个
//    - 每个滤波器中心频率可自适应移动，覆盖 100Hz~10kHz
//    - 陷波器Q 值自适应：Q 越高洞越窄，对正常人声影响越小
//
//  与 AEC 的分工：
//    · AEC（AdaptiveEchoCanceller）→ 消除**可建模**的回声（宽带、人声）
//    · 本模块 → 压制**发散**的啸叫（窄带、正反馈）
//    两者串联，各管一段。
//═══════════════════════════════════════════════════════════════════════════

import Accelerate
import Foundation

/// 自适应啸叫抑制器。
final class HowlingSuppressor {

    // MARK: - 可调参数

    /// 抑制强度 0~1（UI 滑块）。
    /// 提高→ 更早触发、陷波更深 → 啸叫压得快，但人声会略微发闷。
    var strength: Float = 0.6 {
        didSet { strength = min(max(strength, 0), 1) }
    }

    var isEnabled: Bool = true

    /// 是否检测到啸叫（UI 红色警示灯用）。
    private(set) var howlingDetected: Bool = false

    /// 检测到的啸叫频率列表（Hz），供 UI 调试显示。
    private(set) var detectedFrequencies: [Float] = []

    // MARK: - 内部配置

    private let sampleRate: Float
    private let fftSize: Int          // 512
    private let binCount: Int          // 256
    private let hopSize: Int// 128 (75% overlap)

    private let notchCount = 8

    // MARK: - 状态

    /// 自适应陷波器组
    private var notches: [AdaptiveNotch]
    /// 各频点的「历史最大能量」，用于检测能量攀升趋势
    private var energyHistory: [Float]
    /// 频谱分析用的窗口函数（汉宁窗，减少频谱泄漏）
    private var window: [Float]
    /// vDSP 离散傅里叶变换计划（Swift overlay，值类型，无需手工销毁）。
    /// 在 init 里创建一次复用，不要每帧 new —— 内部会分配内存。
    private let dft: vDSP.DiscreteFourierTransform<Float>
    /// overlap-add 用的重叠区
    private var overlap: [Float]

    private var frameCounter: Int = 0
    private let holdFrames = 12          // 连续12 帧(~64ms)超阈值才判定为啸叫

    // MARK: - 初始化

    init(sampleRate: Float = 48000) {
        self.sampleRate = sampleRate
        self.fftSize = 512
        self.binCount = fftSize / 2
        self.hopSize = fftSize / 4

        // 汉宁窗
        // vDSP_hann_window 也要裸指针，且第 3 参数是 Int32
        var w = [Float](repeating: 0, count: fftSize)
        w.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_hann_window(base, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        }
        self.window = w

        // FFT 不再手工管理指针 —— 改用 vDSP.DFT Swift overlay。
        // 它是值类型，创建一次复用，避免每帧分配内存。
        // .realForward = 实数输入的单边谱变换，正好对应原来的 fft_zrip。
        // 512 是 2 的幂，DFT 支持；force unwrap 安全。
        // ★ vDSP 的实数 FFT 在 Swift overlay 里不叫 realForward ——
        //   DFTTransformType 只有 .complexComplex 和 .complexReal 两个 case。
        //   .complexReal 才是「实数输入 → 复数输出」的单边谱变换。
        //
        // ★ 用 DiscreteFourierTransform 而不是 vDSP.DFT ——
        //   vDSP.DFT 类已标记 deprecated，新代码统一用 DiscreteFourierTransform。
        //   它的 init 是 throws（可能因参数非法失败），512 是合法长度。
        //
        //   count 参数是「复数元素个数」。对 .complexReal，
        //   实数输入长度需为 2×count，所以传 fftSize/2 = 256。
        self.dft = try! vDSP.DiscreteFourierTransform(
            count: fftSize / 2,
            direction: .forward,
            transformType: .complexReal,
            ofType: Float.self
        )

        self.energyHistory = [Float](repeating: 0, count: binCount)
        self.overlap = [Float](repeating: 0, count: hopSize)

        //陷波器初始化：均匀铺开在 200Hz ~ 8kHz，初始静默（gain 极低）
        var notches: [AdaptiveNotch] = []
        for i in 0..<notchCount {
            let ratio = Float(i) / Float(notchCount - 1)
            let freq = 200 * pow(8000.0 / 200.0, ratio)
            notches.append(AdaptiveNotch(
                frequency: freq,
                bandwidth: 30,
                depth: 0,      // 未检测到啸叫时深度为 0 = 全通过
                sampleRate: sampleRate
            ))
        }
        self.notches = notches
    }

    // 不需要 deinit：DiscreteFourierTransform 是 Swift 值类型，
    // 不持有需手工销毁的 OpaquePointer（那是老vDSP_fft_zrip 的做法）。

    // MARK: - 主处理

    /// 处理一帧音频（就地修改）。
    func process(_ buf: inout [Float]) {
        guard isEnabled, strength > 0.01 else {
            applyNotches(&buf, strengthOverride: 0)
            howlingDetected = false
            detectedFrequencies = []
            return
        }

        analyzeAndDetect(&buf)
        applyNotches(&buf, strengthOverride: strength)
    }

    // MARK: - 步骤1：频谱趋势检测

    /// 分析当前帧，找出「持续上升的窄带峰」→ 啸叫候选频率。
    private func analyzeAndDetect(_ buf: inout [Float]) {
        let n = buf.count
        guard n >= hopSize else { return }

        // 用 hopSize 的重叠块分析：把当前帧的最后 hopSize 点送进 FFT
        // （本帧处理粒度就是 hopSize，与 iOS 20ms 缓冲对齐）
        let start = n - hopSize
        guard start >= 0 else { return }

        // ── 加窗 ──
        //
        // vDSP.DiscreteFourierTransform 的 .complexReal 模式是 split-complex：
        // 实部数组和虚部数组等长（各 count = fftSize/2）。
        // 而我们的信号是纯实数，所以虚部全0。
        // 这样输入总点数 = fftSize，与设计一致。
        let half = fftSize / 2
        var inReal = [Float](repeating: 0, count: half)
        var inImag = [Float](repeating: 0, count: half)

        // 窗口要用的是「窗的后 hopSize 段」，对应连续分析的重叠区
        let windowStart = fftSize - hopSize
        buf.withUnsafeBufferPointer { src in
            window.withUnsafeBufferPointer { win in
                inReal.withUnsafeMutableBufferPointer { dst in
                    guard let sb = src.baseAddress, let wb = win.baseAddress,
                          let db = dst.baseAddress else { return }
                    vDSP_vmul(sb.advanced(by: start), 1,
                              wb.advanced(by: windowStart), 1,
                              db, 1, vDSP_Length(hopSize))
                }
            }
        }
        // 剩余部分保持 0（补零到 fftSize）

        // ── FFT 与幅度谱 ──
        //
        // ★ 这里原来用 C 风格的 vDSP_ctoz / vDSP_fft_zrip / vDSP_ztoc / vDSP_zvmags，
        //   全部要求 UnsafePointer<DSPSplitComplex> 或 <DSPComplex>，
        //   而我们的数据是普通 [Float] 数组。Swift 不做自动桥接，
        //   手工 withUnsafe 拼指针极易写错（实测反复报错）。
        //
        // 改用 DiscreteFourierTransform 的 split-complex 变体签名：
        //   transform(real:imaginary:) -> (real: [Float], imaginary: [Float])
        // 直接收发数组，类型安全、无指针体操。
        let (dftReal, dftImag) = dft.transform(real: inReal, imaginary: inImag)

        // 幅度谱 = sqrt(re² + im²)
        // .complexReal 输出是共轭对称的，只需前 half 个有效点
        var mags = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            mags[i] = sqrt(dftReal[i] * dftReal[i] + dftImag[i] * dftImag[i])
        }

        // ── 趋势检测 ──
        // 判定条件（三者同时满足）：
        //   ① 当前能量 > 绝对阈值（-45dB，避免在安静时误判）
        //   ② 当前能量 > 历史能量的 N 倍（"突出"的窄带峰）
        //   ③ 峰足够窄（相邻 bin 能量骤降 → 窄带特征）
        let binHz = sampleRate / Float(fftSize)
        let absoluteThreshold: Float = 1e-4 * strength + 2e-5
        let prominenceRatio: Float = 6.0 - strength * 2.0   // 强度越高，判定越激进

        var candidates: [(bin: Int, freq: Float, energy: Float)] = []

        // 只在 150Hz ~ 12kHz 搜索（人声+常见啸叫区）
        let minBin = max(1, Int(150 / binHz))
        let maxBin = min(binCount - 2, Int(12000 / binHz))

        for bin in minBin..<maxBin {
            let cur = mags[bin]

            guard cur > absoluteThreshold else {
                energyHistory[bin] = cur * 0.95 + energyHistory[bin] * 0.05
                continue
            }

            let hist = max(energyHistory[bin], 1e-9)
            let ratio = cur / hist

            // 窄带判定：左右邻域显著低于当前峰
            let leftDrop = mags[max(bin - 3, 0)]
            let rightDrop = mags[min(bin + 3, binCount - 1)]
            let isNarrowBand = cur > leftDrop * 3 && cur > rightDrop * 3

            if ratio > prominenceRatio && isNarrowBand {
                candidates.append((bin, Float(bin) * binHz, cur))
            }

            // 更新历史：上升期快速跟随，下降期缓慢回落
            // （这样历史值总能追上「正在发散」的啸叫，避免只触发一次）
            if cur > energyHistory[bin] {
                energyHistory[bin] = cur * 0.7 + energyHistory[bin] * 0.3
            } else {
                energyHistory[bin] = cur * 0.99 + energyHistory[bin] * 0.01
            }
        }

        // ── 分配陷波器 ──
        if !candidates.isEmpty {
            // 按能量从大到小排序，优先压制最强的
            candidates.sort { $0.energy > $1.energy }
            detectedFrequencies = candidates.prefix(3).map { $0.freq }

            // 找深度最小的陷波器（最"空闲"的）来承担新任务
            var slots = notches.enumerated()
                .sorted { $0.element.depth < $1.element.depth }
                .map { $0.offset }

            for cand in candidates.prefix(notchCount) {
                guard let slot = slots.first(where: { notches[$0].isIdle(cand.freq) }) ?? slots.first
                else { break }

                notches[slot].assign(frequency: cand.freq, depth: min(1.0, 0.4 + strength * 0.6))
                slots.removeAll { $0 == slot }
            }

            frameCounter = 0
            howlingDetected = true
        } else {
            // 无候选 → 陷波器深度缓慢衰减归零（避免啸叫停了还一直闷着）
            frameCounter += 1
            if frameCounter > holdFrames {
                howlingDetected = false
                detectedFrequencies = []
                for i in notches.indices {
                    notches[i].depth *= 0.985
                    if notches[i].depth < 0.01 { notches[i].depth = 0 }
                }
            }
        }
    }

    // MARK: - 步骤2：应用陷波滤波

    private func applyNotches(_ buf: inout [Float], strengthOverride: Float) {
        for i in notches.indices {
            let notch = notches[i]
            guard notch.depth > 0.01 else { continue }

            // currentBiquad 返回的是「系数」(BiquadCoeffs)，
            // process() 定义在「滤波器」(Biquad) 上 —— 需要包一层。
            // 每次重建 Biquad 会清空历史状态，所以先 reset 再设系数，
            // 避免旧的滤波器状态造成输出瞬态爆音。
            var filter = Biquad(notch.currentBiquad(depthScale: strengthOverride))
            filter.reset()
            filter.process(&buf)
        }
    }

    // MARK: - 重置

    /// 连接断开 / 切换房间时调用，清掉所有陷波器状态。
    func reset() {
        for i in notches.indices {
            notches[i] = AdaptiveNotch(
                frequency: notches[i].frequency,
                bandwidth: 30, depth: 0, sampleRate: sampleRate
            )
        }
        energyHistory = [Float](repeating: 0, count: binCount)
        frameCounter = 0
        howlingDetected = false
        detectedFrequencies = []
    }
}

// MARK: - 自适应陷波器

/// 单个自适应陷波器。
/// - `depth`: 0 = 完全旁路（不滤波），1 = 全力压制
/// - `bandwidth`: 陷波带宽(Hz)，越窄对正常声音影响越小
struct AdaptiveNotch {
    var frequency: Float
    var bandwidth: Float
    var depth: Float
    private let sampleRate: Float

    init(frequency: Float, bandwidth: Float, depth: Float, sampleRate: Float) {
        self.frequency = frequency
        self.bandwidth = bandwidth
        self.depth = depth
        self.sampleRate = sampleRate
    }

    /// 当前是否空闲（未被其他频率占用）。
    func isIdle(_ otherFreq: Float) -> Bool {
        if depth < 0.01 { return true }
        // 与已有任务频率相差 >4 倍带宽 → 认为是空闲
        let ratio = otherFreq / max(frequency, 1)
        return ratio < 0.25 || ratio > 4.0
    }

    /// 分配新任务。
    mutating func assign(frequency: Float, depth: Float) {
        self.frequency = frequency
        self.depth = depth
    }

    /// 生成当前应使用的 biquad 系数。
    /// - depthScale: 全局强度缩放（0~1）
    func currentBiquad(depthScale: Float) -> BiquadCoeffs {
        let effectiveDepth = min(depth * depthScale, 1.0)
        guard effectiveDepth > 0.01 else { return .passthrough }

        // 陷波强度：depth=0 时 b0 归零（完全通过）→ depth=1 时标准 notch
        // 通过混合系数实现"可调的陷波深度"
        let standard = BiquadCoeffs.notch(
            f0: frequency,
            q: max(frequency / max(bandwidth, 10), 0.5),
            sampleRate: sampleRate
        )

        // 深度补偿：越浅的陷波，b0 越大（越接近通过）
        let blend = effectiveDepth
        return BiquadCoeffs(
            b0: (1 - blend) * 1.0 + blend * standard.b0,
            b1: (1 - blend) * 0.0 + blend * standard.b1,
            b2: (1 - blend) * 0.0 + blend * standard.b2,
            a1: (1 - blend) * 0.0 + blend * standard.a1,
            a2: (1 - blend) * 0.0 + blend * standard.a2
        )
    }
}
