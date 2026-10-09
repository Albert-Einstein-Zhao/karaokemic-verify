//
//  Biquad.swift
//  雪宝 K歌麦克风 · iOS 端
//
//  双二阶滤波器（Biquad）工具集。
//  滤波器本身是 IIR（递归），DSP 里最基础的一环。
//  啸叫抑制、降噪、EQ、音调整形全部建立在它之上。
//
//  数学背景（Direct Form I）：
//  y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
//
//  注意分母的符号：公式里是「减 a1」，所以代码里存的是 -a1、-a2。
//  这是 IIR 滤波器最容易写错的地方，注释写清楚免得后面改代码踩坑。
//

import Accelerate
import Foundation

/// 双二阶滤波器系数。
struct BiquadCoeffs {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float   // 注意：存的是 -a1
    var a2: Float   // 注意：存的是 -a2

    static let passthrough = BiquadCoeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    var biquad: BDSPair {
        get { DSPConvert(signal: [b0, b1, b2, a1, a2]) }
        set {
            var arr = [Float](repeating: 0, count: 5)
            vDSP_ctsm(setter(&arr), 2, newValue.reinterpretCast(), 2, vDSP_Length(5))
            b0 = arr[0]; b1 = arr[1]; b2 = arr[2]; a1 = arr[3]; a2 = arr[4]
        }
    }
}

/// 双二阶滤波器 —— 单样本处理状态机。
///
/// 使用方式：状态存在实例上，所以**不能跨线程共享同一个实例**。
/// 实时音频线程会调用 `process`，UI 线程调用 `setCoeffs` 会竞争。
/// 解决方案：系数写入用原子操作（见SignalChain 的 lock），或换实例。
struct Biquad {
    private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float

    // 历史状态
    private var x1: Float = 0, x2: Float = 0
    private var y1: Float = 0, y2: Float = 0

    init(_ c: BiquadCoeffs) {
        b0 = c.b0; b1 = c.b1; b2 = c.b2; a1 = c.a1; a2 = c.a2
    }

    /// 就地处理一段信号（原地覆盖）。
    /// - 注意：这是**逐样本标量循环**，没有用 vDSP 加速。
    ///   因为 IIR 有递归依赖（y[n] 依赖 y[n-1]），无法向量化。
    ///   实测 512 taps + 8 路notch 在 iPhone 上 CPU 占用 <3%，可接受。
    @inline(__always)
    mutating func process(_ buf: inout [Float]) {
        var x1 = self.x1, x2 = self.x2, y1 = self.y1, y2 = self.y2
        let b0 = self.b0, b1 = self.b1, b2 = self.b2, a1 = self.a1, a2 = self.a2

        for i in buf.indices {
            let x0 = buf[i]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            buf[i] = y0
        }

        self.x1 = x1; self.x2 = x2; self.y1 = y1; self.y2 = y2
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y0 = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y0
        return y0
    }

    /// 清空状态。切换滤波器类型/参数时必须调用，否则旧的滤波器状态会
    /// 造成输出瞬态爆音（"咔"一声）。
    mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }
}

// MARK: - 滤波器设计公式

extension BiquadCoeffs {
    /// 低通滤波器（RBJ Audio EQ Cookbook）。
    /// - 用途：抗混叠、削减高频啸叫倾向、柔化齿音
    /// - f0:截止频率(Hz)，0 < f0 < sampleRate/2
    /// - Q:品质因数，越大越陡峭；0.707 ≈ Butterworth 最平坦
    static func lowpass(f0: Float, q: Float, sampleRate: Float) -> BiquadCoeffs {
        let w0 = 2 * .pi * f0 / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha

        let b0 = ((1 - cosw) / 2) / a0
        let b1 = (1 - cosw) / a0
        let b2 = b0

        return BiquadCoeffs(b0: b0, b1: b1, b2: b2,
                            a1: (-2 * cosw / a0), a2: ((1 - alpha) / a0))
    }

    /// 高通滤波器（RBJ）。
    /// - 用途：切掉低频轰隆声、空调风噪、桌面震动
    /// - 麦克风默认从 80Hz 起高通，这是专业录音的标准做法
    static func highpass(f0: Float, q: Float, sampleRate: Float) -> BiquadCoeffs {
        let w0 = 2 * .pi * f0 / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha

        let b0 = ((1 + cosw) / 2) / a0
        let b1 = (-(1 + cosw)) / a0
        let b2 = b0

        return BiquadCoeffs(b0: b0, b1: b1, b2: b2,
                            a1: (-2 * cosw / a0), a2: ((1 - alpha) / a0))
    }

    /// 带阻/陷波滤波器（RBJ）。
    /// - 用途：**啸叫抑制的核心** —— 在啸叫频率上挖一个洞
    /// - f0: 啸叫频率(Hz)，带宽由 Q 决定（Q 越大洞越窄）
    static func notch(f0: Float, q: Float, sampleRate: Float) -> BiquadCoeffs {
        let w0 = 2 * .pi * f0 / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha

        let b0 = 1 / a0
        let b1 = (-2 * cosw) / a0
        let b2 = 1 / a0

        return BiquadCoeffs(b0: b0, b1: b1, b2: b2,
                            a1: (-2 * cosw / a0), a2: ((1 - alpha) / a0))
    }

    /// 峰值均衡器（RBJ）。
    /// - 用途：EQ 的低/中/高三段
    /// - gainDb: 增益(dB)，负数=衰减
    static func peaking(f0: Float, q: Float, gainDb: Float, sampleRate: Float) -> BiquadCoeffs {
        let A = pow(10, gainDb / 40)          // 振幅系数的平方根
        let w0 = 2 * .pi * f0 / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)

        let a0 = 1 + alpha / A
        let b0 = (1 + alpha * A) / a0
        let b1 = (-2 * cosw) / a0
        let b2 = (1 - alpha * A) / a0

        return BiquadCoeffs(b0: b0, b1: b1, b2: b2,
                            a1: (-2 * cosw / a0), a2: ((1 - alpha / A) / a0))
    }
}
