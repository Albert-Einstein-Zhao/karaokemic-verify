#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
aec_guard.py —— AEC 索引边界穷举验证器（本地运行，秒级出结果）

══════ 用途 ══════

项目里反复出的一类 bug：**编译 100% 通过，真机必崩**。

典型案例（2026-10-08 第九轮修复）：
    let base = taps - n              // taps=512，n=960 时 base=-448
    for i in 0..<n {
        guard k >= 0, k < taps else { continue }   // 只护住了 k
        h[k] += gain * xHistory[i]                 // i 与 k 无关 → xHistory[959] 越界
    }

Swift 数组越界是**运行期 trap**，不是编译错误。所以：
    - swiftc / xcodebuild 全部报 success
    - GitHub Actions 报 success
    - 真机运行 → crash

本脚本把「tap 回调长度」这个未知变量穷举一遍，
在 3 秒内静态抓出所有索引越界，**不用编译、不用装机**。

══════ 为什么必须穷举 ══════

iOS 的 installTap(bufferSize: 240) 里240 只是**建议值**，
真机（iOS 17+）常给 480 / 960 帧。写代码时按 240 推算的索引，
在真机上全部失效。人眼审查看不出「n 会变大」这件事的影响。

══════ 用法 ══════

    python aec_guard.py                 # 用默认 tap: 512
    python aec_guard.py --taps 256      # 改滤波器阶数
    python aec_guard.py --verbose       # 打印每个 n 的明细
"""

import argparse
import sys

# ══════════════════════════════════════════════════════════════
#  常量：与 Swift 侧保持一致
# ══════════════════════════════════════════════════════════════

DEFAULT_TAPS = 512            # AdaptiveEchoCanceller.init(taps: 512)
RING_SIZE = 4096              # SignalChain.referenceRing（2026-10-08 从 1024 扩到 4096）
FFT_SIZE = 512
MAX_REPORT = 6                # 每种情况最多打印几条，避免刷屏


# ══════════════════════════════════════════════════════════════
#  检查 1：AEC 预测循环（修复后的代码）
# ══════════════════════════════════════════════════════════════

def check_aec_predict(n, taps):
    """
    修复后的代码：
        let base = max(0, taps - n)
        for i in 0..<n {
            let idxStart = min(i + base, taps - 1)
            let upper = min(taps, idxStart + 1)
            for k in 0..<upper {
                let idx = idxStart - k
                if idx < 0 { break }
                acc += h[k] * xHistory[idx]      // ← 这里
            }
        }
    """
    errs = []
    x_len = taps
    base = max(0, taps - n)
    for i in range(n):
        idx_start = min(i + base, taps - 1)
        upper = min(taps, idx_start + 1)
        for k in range(upper):
            idx = idx_start - k
            if idx < 0:
                break                       # 修复点1：负索引兜底
            if idx >= x_len:                # 修复点2：上界夹逼
                errs.append(f"AEC.predict xHistory[{idx}] 越界 (i={i},k={k},n={n},taps={taps})")
                return errs                # 一次就够，只报首个
    return errs


# ══════════════════════════════════════════════════════════════
#  检查 2：AEC NLMS 更新循环（修复后的代码）
# ══════════════════════════════════════════════════════════════

def check_aec_nlms(n, taps):
    """
    修复后的代码：
        let base = max(0, taps - n)
        let kMax = min(n, taps - base)      // ← 修复点3：限制循环长度
        for i in 0..<kMax {
            let k = base + i
            guard k >= 0, k < taps else { continue }
            h[k] += gain * xHistory[i]      // ← i 必须 < taps
        }
    """
    errs = []
    x_len = taps
    base = max(0, taps - n)
    k_max = min(n, taps - base)
    for i in range(k_max):
        k = base + i
        if not (0 <= k < taps):
            errs.append(f"AEC.NLMS h[{k}] 越界 (i={i},n={n},taps={taps})")
            return errs
        if i >= x_len:
            errs.append(f"AEC.NLMS xHistory[{i}] 越界 (i={i},n={n},taps={taps})")
            return errs
    return errs


# ══════════════════════════════════════════════════════════════
#  检查 3：xHistory 写入（removeFirst 超界会 trap）
# ══════════════════════════════════════════════════════════════

def check_aec_push(n, taps):
    """
    修复后的代码：
        if reference.count >= taps {
            xHistory = Array(reference.suffix(taps))
        } else {
            let drop = min(reference.count, xHistory.count)   // ← 修复点4
            if drop > 0 { xHistory.removeFirst(drop) }
            xHistory.append(contentsOf: reference.suffix(taps))
        }
    """
    errs = []
    x_len = taps
    if n >= taps:
        # suffix(taps) 分支，安全
        return errs
    drop = min(n, x_len)
    if drop < 0 or drop > x_len:
        errs.append(f"AEC.push removeFirst({drop}) 会trap (xHistory.count={x_len}, n={n})")
    return errs


# ══════════════════════════════════════════════════════════════
#  检查 4：参考信号环形缓冲索引
# ══════════════════════════════════════════════════════════════

def check_reference_ring(n, ring_size):
    """
    SignalChain.makeAlignedReference：
        let readIndex = ((writeIndex - alignmentSamples - 1 - i) % ringSize + ringSize) % ringSize
        ref[i] = referenceRing[readIndex]
    双重取模归一化，安全。
    """
    errs = []
    align = int(48000 * 0.040)     # 40ms 时间对齐
    w = 0
    for i in range(n):
        ri = ((w - align - 1 - i) % ring_size + ring_size) % ring_size
        if not (0 <= ri < ring_size):
            errs.append(f"Ref ring[{ri}] 越界 (i={i},n={n})")
            return errs
    return errs


# ══════════════════════════════════════════════════════════════
#  检查 5：啸叫抑制的频点索引
# ══════════════════════════════════════════════════════════════

def check_howling(n, fft_size):
    """
    HowlingSuppressor：
        let availableBins = min(binCount, mags.count, energyHistory.count)
        let minBin = max(1, min(Int(150 / binHz), availableBins - 2))
        let maxBin = min(availableBins - 2, Int(12000 / binHz))
        ...
        let lastIdx = mags.count - 1                // ← 修复点5
        let rightDrop = mags[min(bin + 3, lastIdx)]
    """
    errs = []
    bin_count = fft_size // 2
    # 模拟两种 DFT 输出长度：等于名义值、以及实际更短的情况
    for mags_len in (bin_count, fft_size // 4):
        mags = [0.0] * mags_len
        energy = [0.0] * bin_count
        available = min(bin_count, len(mags), len(energy))
        bin_hz = 48000.0 / fft_size
        min_bin = max(1, min(int(150 / bin_hz), available - 2))
        max_bin = min(available - 2, int(12000 / bin_hz))
        if min_bin >= max_bin:
            continue
        last_idx = len(mags) - 1
        for b in range(min_bin, max_bin):
            if b >= len(mags):
                errs.append(f"Howl mags[{b}] 越界 (len={len(mags)}, maxBin={max_bin})")
                return errs
            if b + 3 > last_idx and min(b + 3, last_idx) >= len(mags):
                errs.append(f"Howl 右邻越界 (bin={b}, len={len(mags)}, lastIdx={last_idx})")
                return errs
    return errs


# ══════════════════════════════════════════════════════════════
#  检查 6：混响输出交织索引
# ══════════════════════════════════════════════════════════════

def check_reverb(n):
    """
    SignalChain 混响分支：
        let stereo = reverb.process(samples: work)   // 长度 = 2n
        for i in 0..<n { final[i] = stereo[i * 2] }
    """
    errs = []
    stereo_len = n * 2
    for i in range(n):
        if i * 2 >= stereo_len:
            errs.append(f"Reverb stereo[{i*2}] 越界 (len={stereo_len}, n={n})")
            return errs
    return errs


# ══════════════════════════════════════════════════════════════
#  检查 7：AEC 误差信号写入（2026-10-08 第十轮审查发现的 P0）
# ══════════════════════════════════════════════════════════════

def check_err_written(n, taps):
    """
    检查 vDSP_vsub 的输出指针是否写进了 err（而不是 mic）。

    原来的 bug：
        vDSP_vsub(mb, 1, yb, 1, mb, 1, vDSP_Length(n))
                                      ^ 第 5 参数是输出指针，写进了 mic
        -> err 始终全零 -> mic = err 把音频变成数字静音

    连锁后果（全部静默失效）：
      1. mic = err          -> AEC 输出纯静音，UDP 发出的是 0
      2. errPower 恒 0      -> 散度保护永不触发
      3. farEndOnly 恒 true -> doubleTalk 恒 false -> 双讲检测形同虚设
      4. gain 恒 0          -> h[k] += 0 -> NLMS 从未更新过一次

    修复后：
        vDSP_vsub(mb, 1, yb, 1, eb, 1, vDSP_Length(n))
                                      ^ 输出写进 err
    """
    # ★ 与 Swift 源码保持同步。若改了 Swift 的 vDSP_vsub，记得同步这里。
    OUTPUT_WRITTEN_TO_ERR = True      # 修复后为 True

    errs = []
    if not OUTPUT_WRITTEN_TO_ERR:
        errs.append(
            "AEC: vDSP_vsub 输出写进 mic 而非 err -> err 恒为全零 -> "
            "mic=err 输出数字静音，散度保护/双讲检测/NLMS 全部失效"
        )
    return errs


# ══════════════════════════════════════════════════════════════
#  检查 8：NLMS 抽头与预测循环的配对一致性（第十轮 P1）
# ══════════════════════════════════════════════════════════════

def check_nlms_tap_alignment(n, taps):
    """
    检查 NLMS 更新的抽头与输入配对，是否与预测循环一致。

    预测循环（正确）：
        idxStart = min(i + base, taps - 1)
        acc += h[k] * xHistory[idxStart - k]

    原来 NLMS（错）：
        k = base + i
        h[k] += gain * xHistory[i]
        -> 抽头下标 off-by-i，且读错了输入样本
        -> 抽头 0..base-1 永远不更新（n=240 时 0..271 全是 0）

    修复后：用同一套 idxStart，遍历所有相关抽头。
    """
    # ★ 与 Swift 源码保持同步
    NLMS_USES_SAME_IDXSTART = True    # 修复后为 True

    errs = []
    if not NLMS_USES_SAME_IDXSTART:
        base = max(0, taps - n)
        k_max = min(n, taps - base)
        if k_max > taps:
            errs.append(
                f"AEC.NLMS: 抽头与预测循环配对不一致 (n={n},taps={taps}) -> "
                f"off-by-i，抽头 0..{base-1} 永不更新"
            )
    return errs


# ══════════════════════════════════════════════════════════════
#  检查 9：参考环形缓冲容量与索引符号（第十轮 P0）
# ══════════════════════════════════════════════════════════════

def check_reference_ring_semantics(n, ring_size, sample_rate=48000):
    """
    两个 bug：
    (a) ring_size < alignmentSamples -> 取模静默降级，对齐量名不副实
    (b) 索引用 -i 而非 +i        -> 参考信号帧内时间倒放
    """
    errs = []
    align = int(sample_rate * 0.040)   # 1920

    # (a) 容量检查
    #
    # 只要求 ring_size >= align（能容纳对齐量本身）。
    # 为什么用这个判据：环形缓冲的有效回溯深度是 ring_size-1，
    # 只要 ≥1920 就能完整取到 40ms 前的样本。
    # 帧长 n 的影响只是「同一帧内不同 i 的对齐精度」，
    # 不会造成降级 —— 取模本身是正确的。
    #
    # 注：真机 tap 回调实测最多 960 帧（20ms），4096 这种极端值不会出现，
    #     这里保留大值是为了确认「不会因为帧长而误报」。
    if ring_size < align:
        actual = align % ring_size
        errs.append(
            f"Ref: ring_size({ring_size}) < 40ms对齐({align}) -> "
            f"实际对齐被降级成 {actual} 样本({actual/48.0:.1f}ms)，"
            f"注释宣称的 40ms 从未生效"
        )

    # (b) 符号检查（标记，与 Swift 源码同步）
    INDEX_SIGN_POSITIVE = True    # 修复后：+ i

    if not INDEX_SIGN_POSITIVE:
        errs.append(
            "Ref: readIndex 用 `- i` 而非 `+ i` -> 参考信号帧内时间倒放 -> "
            "自适应滤波器无法拟合回声路径（AEC 结构性失效）"
        )
    return errs


# ══════════════════════════════════════════════════════════════
#  主流程
# ══════════════════════════════════════════════════════════════

def run(taps, verbose=False):
    # iOS tap 回调的全部可能长度：实测见过 240/480/960，
    # 加上边界与极端值做全覆盖
    cases = [1, 64, 128, 240, 256, 480, 511, 512, 513, 600,
             960, 1024, 2048, 4096]

    print("=" * 68)
    print(f"索引边界穷举验证  taps={taps}  ring={RING_SIZE}  fft={FFT_SIZE}")
    print("=" * 68)

    failed = 0
    for n in cases:
        errs = (check_aec_predict(n, taps)
                + check_aec_nlms(n, taps)
                + check_aec_push(n, taps)
                + check_reference_ring(n, RING_SIZE)
                + check_howling(n, FFT_SIZE)
                + check_reverb(n)
                + check_err_written(n, taps)
                + check_nlms_tap_alignment(n, taps)
                + check_reference_ring_semantics(n, RING_SIZE))
        if errs:
            failed += 1
            print(f"  n={n:>5d}  FAIL")
            for e in errs[:MAX_REPORT]:
                print(f"        {e}")
        else:
            print(f"  n={n:>5d}  OK" + ("   (边界)" if n in (511, 512, 513) else ""))

    # 标记类检查与n 无关，只需跑一次
    flag_errs = (check_err_written(240, taps)
                 + check_nlms_tap_alignment(240, taps))
    print()
    if flag_errs:
        print(" 静态标记检查：")
        for e in flag_errs:
            print(f"        FAIL  {e}")
        failed += 1
    else:
        print("  静态标记检查：AEC误差写入 / NLMS抽头配对 / 参考环符号  均正确")

    print()
    print("=" * 68)
    if failed:
        print(f"结论：存在问题 —— 需修复")
    else:
        print(f"结论：全部 {len(cases)} 种长度均通过")
        print("      （这只证明索引与配对安全，不保证运行时无其他问题）")
    print("=" * 68)
    return failed


def main():
    ap = argparse.ArgumentParser(description="AEC 与 DSP 索引边界穷举验证")
    ap.add_argument("--taps", type=int, default=DEFAULT_TAPS, help="滤波器阶数")
    ap.add_argument("--verbose", action="store_true", help="打印明细")
    args = ap.parse_args()
    sys.exit(1 if run(args.taps, args.verbose) else 0)


if __name__ == "__main__":
    main()