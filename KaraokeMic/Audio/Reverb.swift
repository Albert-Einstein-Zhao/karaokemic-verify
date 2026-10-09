//
//  Reverb.swift
//  雪宝 K歌麦克风 · iOS 端
//
//  ════════════════════════════════════════════════════════════════════════
//  混响（Reverb）—— 你要求的"可调混响效果"
//  ════════════════════════════════════════════════════════════════════════
//
//  原理：一段声音在房间里会经历多次反射（墙面、天花板、家具），
//       这些反射叠加在一起就是我们听到的"空间感"。
//       混响器就是用数字方式模拟这些反射。
//
//  经典结构（Schroeder / Freeverb）：
//
//    输入 ──┬──┬──┬──┬──┬──┬──┬──┬──┐   ← 8 路梳状滤波器(Combs)
//           │  │  │  │  │  │  │  │  │      产生"早期反射+密集回声"
//           ▼  ▼  ▼  ▼  ▼  ▼  ▼  ▼  ▼
//           └──┴──┴──┴──┴──┴──┴──┴──┴──┐
//                                          ▼
//                                      ┌───────────┐
//                                      │  干湿混合 │ ← 关键参数 wet/dry
//                                      └───────────┘
//                        ┌──┐    ┌──┐    ┤
//                        └──┘    └──┘    │      ← 4 路全通滤波器(Allpass)
//                        AP1    AP2...─┘         修正梳状滤波的染色，
//                                                让混响更"自然"
//  ════════════════════════════════════════════════════════════════════════
//
//  K歌场景的特殊考量：
//   ⚠️ 混响**只能加在麦克风路**（你的声音），绝不能加在伴奏上
//      —— 伴奏是别的 App 放的，我们加不了（也不该加）
//      所以这里的混响效果 = 只给你的人声加"卡拉OK 厅堂感"，
//      这是专业卡拉OK 设备的做法（原唱声加混响，伴奏不加）。
//
//   ⚠️ 混响会拖慢声音的时间包络 → 让人声"糊"掉，听不清歌词。
//      所以 wet 量不宜过大，默认 18%，且提供 dry 预设（完全不加混响）。
//
//═══════════════════════════════════════════════════════════════════════════

import Foundation

/// 混响预设。
enum ReverbPreset: String, CaseIterable, Codable, Identifiable {
    case dry          // 干声
    case smallRoom    // 小房间
    case musicHall// 音乐厅
    case stage        // 舞台
    case fullArena    // 全场/大礼堂

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dry:return "干声"
        case .smallRoom:    return "小房间"
        case .musicHall:    return "音乐厅"
        case .stage:return "舞台"
        case .fullArena:    return "全场"
        }
    }

    var subtitle: String {
        switch self {
        case .dry:        return "纯净人声"
        case .smallRoom:   return "居家感·轻"
        case .musicHall:   return "开阔·大气"
        case .stage:       return "贴脸·有力"
        case .fullArena:   return "宏大·震撼"
        }
    }

    /// 该预设的默认参数。
    var parameters: ReverbParameters {
        switch self {
        case .dry:
            return ReverbParameters(wet: 0.0, damping: 0.5, roomSize: 0.0, width: 0.5)
        case .smallRoom:
            return ReverbParameters(wet: 0.12, damping: 0.65, roomSize: 0.45, width: 0.6)
        case .musicHall:
            return ReverbParameters(wet: 0.20, damping: 0.55, roomSize: 0.72, width: 0.8)
        case .stage:
            return ReverbParameters(wet: 0.16, damping: 0.40, roomSize: 0.58, width: 0.7)
        case .fullArena:
            return ReverbParameters(wet: 0.28, damping: 0.50, roomSize: 0.92, width: 1.0)
        }
    }
}

/// 混响参数（全部归一化到 0~1 或对应物理量）。
struct ReverbParameters: Codable, Equatable {
    /// 湿声比例 0~1。0=全干，1=全是混响。
    var wet: Float
    /// 高频阻尼0~1。越大，高频衰减越快（听起来越"闷"，更远）。
    var damping: Float
    /// 房间尺寸 0~1。影响梳状滤波的反馈强度→ 混响长度。
    var roomSize: Float
    /// 立体声宽度 0~1。单声道输入时影响左右延迟差。
    var width: Float

    static let `default` = ReverbParameters(wet: 0.18, damping: 0.55, roomSize: 0.5, width: 0.7)
}

/// Freeverb 结构的立体声混响器。
///
/// 延迟线长度按 48kHz 标定，对其他采样率线性缩放。
/// （标定依据：Freeverb tunings 公开数据，单位为样本数@44100）
final class Reverb {

    // MARK: - 梳状滤波器组

    /// Freeverb 8 梳状滤波器的延迟（44100Hz 标定值，单位：样本数）
    private static let combTunings44100: [Int] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    /// 立体声右声道偏移（微小时延，展宽立体感）
    private static let stereoSpread44100: Int = 23
    /// 全通滤波器延迟
    private static let allpassTunings44100: [Int] = [556, 441, 341, 225]
    private static let allpassStereoSpread44100: Int = 23

    private let combs: [CombFilter]
    private let allpasses: [AllPassFilter]

    /// 左右声道各自的输入预延迟（实现立体声展宽）
    private let preDelayL: DelayLine
    private let preDelayR: DelayLine

    // MARK: - 参数

    private var params: ReverbParameters
    private let sampleRate: Float

    /// 全局使能（干声预设 = 关掉，省 CPU）
    var isEnabled: Bool = true

    // MARK: - 反馈与滤波状态

    private var feedback: Float = 0.84
    private var damp1: Float = 0.2
    private var damp2: Float = 0.2

    private let dryBufferL: [Float]
    private let dryBufferR: [Float]

    // MARK: - 初始化

    init(sampleRate: Float = 48000, parameters: ReverbParameters = .default) {
        self.sampleRate = sampleRate
        self.params = parameters

        // 按采样率缩放延迟线长度
        let scale = sampleRate / 44100.0

        // ★ 左右声道使用独立的延迟线，且 R 声道比 L 稍长（约 23 样本 ≈ 0.5ms）
        //   这个微小差异会产生"空间展宽"的立体感。
        let spread = Int(Float(Reverb.stereoSpread44100) * scale)

        self.combs = Reverb.combTunings44100.enumerated().map { idx, tuning in
            let baseDelay = Int(Float(tuning) * scale)
            // 偶数索引的延迟线加宽（这是 Freeverb 官方做法的一半，
            // 我们用更保守的 spread，避免过度展宽听起来假）
            return CombFilter(
                delaySamples: baseDelay,
                delaySamplesR: baseDelay + spread,
                feedback: 0.84,
                dampCoef: 0.3
            )
        }

        self.allpasses = Reverb.allpassTunings44100.enumerated().map { idx, tuning in
            AllPassFilter(
                delaySamples: Int(Float(tuning) * scale),
                gain: 0.5
            )
        }

        // 预延迟：10ms 左右，模拟声音从嘴到墙的直达距离差
        let preDelaySamples = Int(sampleRate * 0.012)
        self.preDelayL = DelayLine(size: max(preDelaySamples, 16))
        self.preDelayR = DelayLine(size: max(preDelaySamples + 12, 16))

        let maxBlock = 4096
        self.dryBufferL = [Float](repeating: 0, count: maxBlock)
        self.dryBufferR = [Float](repeating: 0, count: maxBlock)

        updateDerivedParameters()
    }

    // MARK: - 参数更新

    func update(parameters: ReverbParameters) {
        params = parameters
        updateDerivedParameters()
        // wet=0 时直接旁路，省 CPU
        isEnabled = parameters.wet > 0.005
    }

    private func updateDerivedParameters() {
        // 反馈量：roomSize 越大 → 反馈越强 → 混响尾巴越长
        // Freeverb 原始范围 0.7~0.95
        feedback = 0.70 + params.roomSize * 0.26

        // 阻尼：damping 越大 → damp 系数越大 → 高频衰减越快
        // damp = 1 - damping*0.4 ，范围 0.6~1.0
        let dampTarget = 1.0 - params.damping * 0.4
        damp1 = dampTarget
        damp2 = dampTarget
    }

    // MARK: - 音频处理

    /// 处理一帧单声道音频，输出立体声。
    /// - Parameter samples: 输入单声道
    /// - Returns: 立体声混响后的结果（左右声道交织：L,R,L,R...）
    func process(samples: [Float]) -> [Float] {
        let n = samples.count

        // 旁路：干声预设 → 原样返回复制成立体声
        guard isEnabled, params.wet > 0.005 else {
            var out = [Float](repeating: 0, count: n * 2)
            for i in 0..<n {
                out[i * 2] = samples[i]
                out[i * 2 + 1] = samples[i]
            }
            return out
        }

        var inputL = [Float](repeating: 0, count: n)
        var inputR = [Float](repeating: 0, count: n)
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        // ★ 2026-10-08 新增：保留未经预延迟的原始干声。
        //   预延迟是 12ms延迟线，直接拿延迟后的信号当干声会让干声后移。
        var dryL = [Float](repeating: 0, count: n)
        var dryR = [Float](repeating: 0, count: n)

        // 预延迟 + 立体声展宽：右声道延迟略长 → 产生"空间展宽"感
        for i in 0..<n {
            dryL[i] = samples[i]
            dryR[i] = samples[i]
            inputL[i] = preDelayL.process(samples[i])
            inputR[i] = preDelayR.process(samples[i])
        }

        // 干声直接拷贝
        for i in 0..<n {
            outL[i] = inputL[i]
            outR[i] = inputR[i]
        }

        // ── 梳状 + 全通滤波器组：产生密集反射 ──
        // ★ 修复：原代码把梳状输出累加成标量 wetSumL，
        //   然后全通滤波器循环 n 次每次都喂同一个标量、只用最后一次结果，
        //   等于只有 1 个样本过了全通 → 混响几乎全丢。
        //   正确做法：每个样本独立走一遍完整链路。
        var wetL = [Float](repeating: 0, count: n)
        var wetR = [Float](repeating: 0, count: n)

        for i in 0..<n {
            let inL = inputL[i]
            let inR = inputR[i]

            var combOutL: Float = 0
            var combOutR: Float = 0

            for ci in 0..<combs.count {
                let comb = combs[ci]
                combOutL += comb.processL(inL)
                combOutR += comb.processR(inR)
            }

            // ── 全通滤波器组：修正梳状滤波的"染色"，让混响更自然 ──
            var xL = combOutL
            var xR = combOutR

            for ap in allpasses {
                xL = ap.process(xL)
                xR = ap.process(xR)      // 简化：左右共用滤波系数，差异来自前面的预延迟
            }

            wetL[i] = xL
            wetR[i] = xR
        }

        // ── 干湿混合 ──
        let wet = params.wet
        let dry = 1.0 - wet
        var result = [Float](repeating: 0, count: n * 2)

        for i in 0..<n {
            // 立体声宽度：width=0 → 左右相同（单声道化）；width=1 → 完全展开
            let mid = (wetL[i] + wetR[i]) * 0.5
            let side = (wetL[i] - wetR[i]) * 0.5 * params.width

            let outWetL = mid + side
            let outWetR = mid - side

            // ★ 2026-10-08 修复：干声改用未经预延迟的 dryL/dryR。
            //   原用 outL/outR（= 预延迟后的信号），干声会整体后移 12ms
            //   且刚启动时前 12ms 干声偏小。
            result[i * 2]     = dry * dryL[i] + wet * outWetL
            result[i * 2 + 1] = dry * dryR[i] + wet * outWetR
        }

        return result
    }

    // MARK: - 重置

    func reset() {
        for i in combs.indices { combs[i].reset() }
        for ap in allpasses { ap.reset() }
        preDelayL.reset()
        preDelayR.reset()
    }
}

// MARK: - 基础组件

/// 环形延迟线。
private final class DelayLine {
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private let size: Int

    init(size: Int) {
        self.size = size
        self.buffer = [Float](repeating: 0, count: size)
    }

    /// 标准用法：读一个延迟样本，然后把新样本写进去。
    @inline(__always)
    func process(_ input: Float) -> Float {
        let output = buffer[writeIndex]
        buffer[writeIndex] = input
        writeIndex = (writeIndex + 1) % size
        return output
    }

    /// 覆写最近一次写入的位置（不推进指针）。
    /// 用于全通滤波器：先 process(0) 取出 y[n-M]，再用 overwriteLatest
    /// 把新算出的 y[n] 写到同一格。
    @inline(__always)
    func overwriteLatest(_ value: Float) {
        let idx = (writeIndex - 1 + size) % size
        buffer[idx] = value
    }

    func reset() {
        for i in buffer.indices { buffer[i] = 0 }
        writeIndex = 0
    }
}

/// 梳状滤波器：y[n] = x[n] + feedback * (damp滤波后的 y[n-delay])
///
/// ⚠️ 左右声道必须用**独立的延迟线和状态**，否则两个声道会互相污染
///    （写入L 之后 R 立刻读到 L 的值，声道分离就没了）。
private final class CombFilter {
    private let delayLineL: DelayLine
    private let delayLineR: DelayLine
    private let feedback: Float
    /// 一阶低通阻尼系数：越大高频衰减越快（听起来更"远"）
    private let dampCoef: Float

    // 左右各自独立的滤波状态
    private var storeL: Float = 0
    private var storeR: Float = 0

    init(delaySamples: Int, delaySamplesR: Int, feedback: Float, dampCoef: Float) {
        self.delayLineL = DelayLine(size: max(delaySamples, 1))
        self.delayLineR = DelayLine(size: max(delaySamplesR, 1))
        self.feedback = feedback
        self.dampCoef = dampCoef
    }

    @inline(__always)
    func processL(_ input: Float) -> Float {
        let delayed = delayLineL.process(input)
        storeL = delayed * (1 - dampCoef) + storeL * dampCoef
        return input + storeL * feedback
    }

    @inline(__always)
    func processR(_ input: Float) -> Float {
        let delayed = delayLineR.process(input)
        storeR = delayed * (1 - dampCoef) + storeR * dampCoef
        return input + storeR * feedback
    }

    func reset() {
        storeL = 0; storeR = 0
        delayLineL.reset(); delayLineR.reset()
    }
}

/// 全通滤波器（Schroeder 形式）。
///
///   y[n] = -g · x[n] + x[n-M] + g · y[n-M]
///
/// 只需要一条延迟线：延迟线里同时保存 M 个样本前的**输入**
/// 与 M 个样本前的**输出**（交替存放在不同的位置）。
/// 这里是标准实现，读写分离：
///   bufIn[M]  → x[n-M]
///   bufOut[M] → y[n-M]
private final class AllPassFilter {
    private let delayIn: DelayLine
    private let delayOut: DelayLine
    private let gain: Float

    init(delaySamples: Int, gain: Float) {
        let m = max(delaySamples, 1)
        self.delayIn = DelayLine(size: m)
        self.delayOut = DelayLine(size: m)
        self.gain = gain
    }

    @inline(__always)
    func process(_ input: Float) -> Float {
        let xDelayed = delayIn.process(input)     // x[n-M]
        let yDelayed = delayOut.process(0)          // 取出 y[n-M]，马上写入新输出
        let output = -gain * input + xDelayed + gain * yDelayed
        // 把刚算出的输出写回 delayOut 的当前位置（覆盖掉那个 0）
        delayOut.overwriteLatest(output)
        return output
    }

    func reset() {
        delayIn.reset()
        delayOut.reset()
    }
}
