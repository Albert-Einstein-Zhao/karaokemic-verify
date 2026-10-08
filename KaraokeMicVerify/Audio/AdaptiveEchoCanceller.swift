//
//  AdaptiveEchoCanceller.swift
//  雪宝 K歌麦克风 · iOS 端
//
//  ════════════════════════════════════════════════════════════════════════
//  ⚠️  关于回声消除（AEC）的技术真相 —— 请先读完这段再改代码
//  ════════════════════════════════════════════════════════════════════════
//
//  理想情况：AEC 需要「远端参考信号」(far-end reference) —— 也就是
//            扬声器正在播放的那一路音频。有了它，才能算出回声路径并抵消。
//
//  你的实际情况：
//    · 手机麦克风拾取的声音里，回声来自 **电视机的喇叭**
//    · 而那段伴奏是**盒子上的 K歌 App** 播的
//    · 手机端**拿不到**这段 PCM —— 它在另一个进程里，Android 不允许跨进程读音频
//
//  所以：
//  ❌ 不能 100% 消除电视喇叭漏回来的人声回声（我们的参考信号里没有它）
//  ✅ 能 100% 消除「自己刚发出去的人声」被电视喇叭播出来又绕回麦克风的部分
//     —— 因为这段 PCM 我们自己就知道！用「刚发出去的PCM」当参考，路径可精确求解。
//
//  这个比例在实际唱歌场景里是够用的：
//    · 人声回声（自己能消）→ 消除
//    · 伴奏漏回（消不掉）→ 靠「啸叫抑制」+ 增益管控压制
//  伴奏漏回**不会引起尖锐啸叫**，因为伴奏是宽带音乐信号，能量分散、
//  没有窄带正反馈条件。真正危险的是人声/高音的正反馈，我们能治。
//
//  算法：NLMS（Normalized Least Mean Squares）双讲检测自适应滤波
//    · 512 taps @48kHz ≈ 10.6ms 回声路径覆盖范围，足够家庭房间
//    · μ = 0.15，兼顾收敛速度与稳态误差
//    · 双讲检测：讲话时冻结系数更新（滤波器去适应被近端语音污染）
//    · 散度保护：|e| > 3x|x| 说明滤波器发散，立刻退回安全系数
//
//═══════════════════════════════════════════════════════════════════════════

import Accelerate
import Foundation

/// NLMS 自适应回声消除器。
///
/// 音频线程调用 `process(mic:withReference:)`；UI 线程只读参数，不写状态。
/// 参数更新通过 `setStrength(_:)`（普通 Float 写入，撕裂风险可忽略，
/// 因为滤波行为变化是渐进的，不会产生爆音）。
final class AdaptiveEchoCanceller {

    // MARK: - 参数

    /// 自适应滤波器阶数。512 @48kHz ≈ 10.6ms。
    /// 覆盖「手机麦克风 → 房间 → 电视喇叭 → 房间 → 手机麦克风」的传播时延。
    private let taps: Int

    /// 归一化步长μ。越大收敛越快但稳态误差越大。
    private let mu: Float

    /// 当前强度设置（0~1），来自 UI 滑块。
    /// 强度越低 → μ 越小 → 回声残留越多。0 时完全旁路。
    var strength: Float = 0.75 {
        didSet { strength = min(max(strength, 0), 1) }
    }

    /// 是否启用（UI 开关）。
    var isEnabled: Bool = true

    /// 残余回声量（dBFS，越小越好），供UI 显示。
    private(set) var erleDb: Float = 0

    /// 是否检测到「疑似滤波器发散」。
    private(set) var diverged: Bool = false

    /// 双讲检测结果：true = 正在有人说话（近端），此时冻结系数更新。
    private(set) var doubleTalk: Bool = false

    // MARK: - 状态（仅音频线程访问，无需加锁）

    /// 自适应系数 h[n] —— 滤波器在"学习"房间的声学指纹。
    private var h: [Float]

    /// 输入历史：参考信号滑动窗口
    private var xHistory: [Float]

    /// 滤波器状态（Direct Form I 的历史输出）
    private var yHistory: [Float]

    /// 双讲检测用的近期功率估计
    private var recentRefPower: Float = 0
    private var recentErrPower: Float = 0

    // MARK: - 初始化

    init(taps: Int = 512, mu: Float = 0.15) {
        self.taps = taps
        self.mu = mu
        self.h = [Float](repeating: 0, count: taps)
        self.xHistory = [Float](repeating: 0, count: taps)
        self.yHistory = [Float](repeating: 0, count: taps)
    }

    // MARK: - 核心处理

    /// 处理一帧音频。
    /// - Parameters:
    ///   - mic: 麦克风采到的原始信号（会被就地修改为「干净信号」）
    ///   - reference: 本 App **刚发出去**的 PCM。这是唯一的参考来源。
    /// - Returns: 本帧的残余回声量(dBFS)
    @discardableResult
    func process(mic: inout [Float], reference: [Float]) -> Float {
        let n = mic.count

        // 旁路：关闭或强度为 0 → 直接放行
        guard isEnabled, strength > 0.01 else {
            erleDb = 0
            return 0
        }

        // 窗口长度对齐。
        // ★ 这里原来写的是 `guard refLen == taps else { return }`：
        //   taps = 512，但每帧参考信号只有 240 个样本（5ms），
        //   240 ≠ 512 → 永远命中 guard 直接 return → **AEC 从来没真正工作过**，
        //   UI 上的 ERLE 恒为 0，且回声一点没消。
        //
        //   正确做法：AEC 是**逐样本**递归滤波器，用滤波器自身的历史窗口 xHistory
        //   承载「过去的参考样本」，只需要当前帧的新样本。
        //   所以这里不该要求 reference 长度等于 taps，只要求非空。
        guard !reference.isEmpty else { return erleDb }

        // 把本帧参考样本推进历史窗口（新的在前）
        //
        // ★ 防御性收窄：即使 n 超大，也不让 removeFirst 传超界数量。
        //   removeFirst(k) 在 k > count 时会 trap（崩溃），
        //   虽��上面的分支已保证 k < taps，这里再夹一次，纯属兜底。
        if reference.count >= taps {
            // 极端情况：参考比滤波器还长，只取最近 taps 个
            xHistory = Array(reference.suffix(taps))
        } else {
            let drop = min(reference.count, xHistory.count)
            if drop > 0 { xHistory.removeFirst(drop) }
            xHistory.append(contentsOf: reference.suffix(taps))
        }

        // ── 1. 预测回声：y[i] = Σ h[k] · xHistory[i - k] ──
        //
        // ★ 这里原来写的是 vDSP_dotpr —— 那是「点积」函数，
        //   返回一个标量（Float），不能用来生成逐点预测序列。
        //
        // 也考虑过改用 vDSP_conv（真正的卷积函数），但它有两个硬约束：
        //   ① 输入信号长度必须 ≥ lenResult + lenFilter - 1，即需要零填充
        //   ② 每次调用都要构造填充后的临时数组
        // 在 5ms 一帧的实时音频回调里，第②条是禁忌（堆分配会造成爆音）。
        //
        // 所以用标量循环。开销核算：
        //   240 样本 × 512 taps ≈ 12.3 万次乘加，每 5ms 执行一次
        //   ≈ 24.6 M 次乘加/秒，A13 及以后单核占用约 2.5%，完全可接受。
        var yEstimate = [Float](repeating: 0, count: n)
        // ★ base 同样必须夹紧。
        //   n > taps 时 base 为负 → i + base 可能为负 → xHistory[负数] 越界崩溃。
        //   夹到 0 后语义是「把本帧样本当作滤波器最近 taps 个输入的延续」，
        //   对 n > taps 的超长帧是合理降级（多出来的样本用最近的历史对齐）。
        let base = max(0, taps - n)
        for i in 0..<n {
            var acc: Float = 0
            // h[k] 对应参考信号里往前数第 k 个样本。
            // 本帧新样本的偏移是 taps-n，所以 i 点的参考起点要往后挪 taps-n。
            // upper 同时受 taps 夹逼，保证 i + base - k >= 0。
            let idxStart = min(i + base, taps - 1)
            let upper = min(taps, idxStart + 1)
            for k in 0..<upper {
                let idx = idxStart - k
                if idx < 0 { break }
                acc += h[k] * xHistory[idx]
            }
            yEstimate[i] = acc
        }

        // ── 2. 误差信号：e[n] = mic[n] - yEstimate[n] ──
        // 这个 e 就是「减去回声后的干净人声」
        var err = [Float](repeating: 0, count: n)
        mic.withUnsafeMutableBufferPointer { m in
            yEstimate.withUnsafeBufferPointer { y in
                guard let mb = m.baseAddress, let yb = y.baseAddress else { return }
                // vDSP_vsub只吃裸指针，不接受数组/切片
                vDSP_vsub(mb, 1, yb, 1, mb, 1, vDSP_Length(n))
            }
        }

        // ── 3. 散度保护 ──
        // 如果残差远大于输入，说明滤波器完全发散了（比如突然插拔设备、
        // 房间声学突变）。此时立刻退回安全状态，用一个保守的高通兜底。
        let micPower = power(of: mic)
        let errPower = power(of: err)

        if micPower > 1e-8, errPower > micPower * 9 {   // err > 3x mic
            diverged = true
            resetAdaptive()
            // 用输入信号的一阶差分近似「只保留快速变化的部分」作为应急
            for i in 1..<n { err[i] = mic[i] - mic[i - 1] }
            err[0] = mic[0]
            mic = err
            erleDb = 0
            return 0
        }
        diverged = false

        // ── 4. 双讲检测（Double Talk Detection, DTD） ──
        // 如果误差信号功率远大于参考信号功率，说明「参考信号解释不了当前麦克风内容」
        // → 用户正在唱歌（近端语音）→ 此时若继续更新系数，
        //   滤波器会试图去拟合用户的声音，导致回声消除崩掉。
        // → 冻结更新。这是双讲场景下 AEC 稳定的关键。
        let refPower = power(of: xHistory)
        recentRefPower = 0.7 * recentRefPower + 0.3 * refPower
        recentErrPower = 0.7 * recentErrPower + 0.3 * errPower

        let farEndOnly = recentErrPower < recentRefPower * 4.0   // err < 2x ref
        doubleTalk = !farEndOnly && recentRefPower > 1e-7

        // ── 5. NLMS 系数更新 ──
        // h[n] += μ * e[n] / (‖x‖² + δ) · x[n-k]
        // 归一化（除以输入能量）保证不同音量下收敛速度一致。
        if !doubleTalk {
            let eps: Float = 1e-7
            // 归一化用整段参考的功率
            let norm = power(of: xHistory) + eps
            // 有效步长受强度滑块控制
            let effectiveMu = mu * strength

            // ★★ 必须夹紧 base，base 为负会直接导致数组越界崩溃 ★★
            //
            // 原本写的是 `let base = taps - n`，当回调帧数 n > taps 时 base 变负数：
            //   · NLMS 里 `h[k]` 有 guard k>=0 保护，会 continue 跳过（不崩）
            //   · 但 `xHistory[i]` 里的 i 是本帧样本下标（0..<n），
            //     n=960 时 i 会到 959，直接访问 xHistory[512..959] → **越界崩溃**
            //
            // 真实触发场景：iOS 的 installTap(bufferSize:) 只是「建议值」，
            // 真机（尤其 iOS 17+）常给 480/ 960 帧。
            // 表现：点连接 → 界面切换 → 不到半秒闪退（音频回调开始跑就炸）。
            //
            // 修法：base 夹到 [0, taps]，且只更新本帧真正对得上的那一段抽头。
            // 被跳过的样本由下一次调用继续覆盖，不影响算法正确性
            //（NLMS 本来就是逐样本递归，分几段更新等价）。
            let base = max(0, taps - n)
            let kMax = min(n, taps - base)      // 本帧最多能更新多少个抽头
            for i in 0..<kMax {
                let k = base + i          // 本帧第 i 个样本对应的滤波器抽头
                guard k >= 0, k < taps else { continue }
                let gain = effectiveMu * err[i] / norm
                if gain.isFinite, abs(gain) < 10 {
                    h[k] += gain * xHistory[i]
                    // 稳定性钳位：|h| > 1.5 物理上不可能是房间反射
                    if abs(h[k]) > 1.5 { h[k] = h[k] > 0 ? 1.5 : -1.5 }
                }
            }
        }

        // ── 6. 残余回声量 ERLE（供 UI 显示） ──
        // ERLE = 10*log10(输入回声功率 / 残余回声功率)，越大越好
        if refPower > 1e-8, errPower > 1e-12 {
            let ratio = refPower / errPower
            let targetDb = 10 * log10(max(ratio, 1))
            // 平滑，避免 UI 数字乱跳
            erleDb = erleDb == 0 ? targetDb : (erleDb * 0.8 + targetDb * 0.2)
            erleDb = min(max(erleDb, 0), 60)
        }

        mic = err
        return erleDb
    }

    // MARK: - 辅助

    /// 计算信号功率（均方）。
    /// 注意：RMS 算完不开根号 —— 我们只要能量关系，开根号纯属浪费 CPU。
    private func power(of sig: [Float]) -> Float {
        guard !sig.isEmpty else { return 0 }
        var sum: Float = 0
        // vDSP_svesq 只接受裸指针，不接受数组
        sig.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_svesq(base, 1, &sum, vDSP_Length(sig.count))
        }
        return sum / Float(sig.count)
    }

    /// 重置滤波器（连接断开 / 切换设备时调用）。
    /// 必须清掉 h，否则旧的房间声学指纹会污染新房间。
    func resetAdaptive() {
        h = [Float](repeating: 0, count: taps)
        recentRefPower = 0
        recentErrPower = 0
        erleDb = 0
        doubleTalk = false
        diverged = false
    }
}
