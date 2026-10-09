//
//  Theme.swift
//  雪宝 K歌麦克风 · iOS 端
//
//  设计系统：★ 苹果风（2026-10-09 第二十四轮重做）
//
//  直接对齐 iOS 深色模式的 System Colors，与盒子端 UI 用同一套色板：
//    systemBackground            #000000
//    secondarySystemBackground   #1C1C1E   （卡片底色）
//    systemBlue  (dark)          #0A84FF   （唯一强调色）
//    systemGreen (dark)          #30D158
//    systemOrange(dark)          #FF9F0A
//    systemRed   (dark)          #FF453A
//    separator                   #38383A
//
//  与上一版「深色影院风 + 青紫渐变 + 液态玻璃」的三点不同：
//   ① 背景纯黑 —— 深蓝底会让界面像「播放器皮肤」而不是系统级界面
//   ② 强调色收敛为单一蓝 —— 一屏一个强调色是苹果的基本纪律
//   ③ 卡片去掉重阴影与顶部高光 —— iOS 靠**背景色差**分层，不靠阴影
//      大阴影在 OLED 上会糊成一团灰，是「没质感」的主要来源
//

import SwiftUI

enum KaraokeTheme {

    // MARK: - 背景色（iOS systemBackground）

    static let bgTop = Color(red: 0.0, green: 0.0, blue: 0.0)             // #000000
    static let bgBottom = Color(red: 0.039, green: 0.039, blue: 0.043)    // #0A0A0B
    static let bgGradient = LinearGradient(
        colors: [bgTop, bgBottom],
        startPoint: .top,
        endPoint: .bottom
    )

    /// 卡片底色 = secondarySystemBackground #1C1C1E
    static let cardBackground = Color(red: 0.109, green: 0.109, blue: 0.118)
    /// 三级背景（卡片内的浅色块，如按键标签）#2C2C2E
    static let cardBackgroundElevated = Color(red: 0.173, green: 0.173, blue: 0.180)
    /// iOS 分隔线 #38383A
    static let separator = Color(red: 0.220, green: 0.220, blue: 0.227)

    // MARK: - 强调色（单一 systemBlue）

    static let accentCyan = Color(red: 0.039, green: 0.518, blue: 1.0)    // #0A84FF
    static let accentPurple = Color(red: 0.749, green: 0.353, blue: 0.949) // #BF5AF2
    static let accentGradient = LinearGradient(
        colors: [accentCyan, accentCyan.opacity(0.75)],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let accentGlow = RadialGradient(
        colors: [accentCyan.opacity(0.22), .clear],
        center: .center,
        startRadius: 0,
        endRadius: 160
    )

    // MARK: - 语义色（iOS dark variant）

    static let success = Color(red: 0.188, green: 0.820, blue: 0.345)     // #30D158
    static let warning = Color(red: 1.0, green: 0.624, blue: 0.039)       // #FF9F0A
    static let danger = Color(red: 1.0, green: 0.271, blue: 0.227)        // #FF453A
    static let latencyGood = success
    static let latencyFair = warning
    static let latencyPoor = danger

    // MARK: - 文字层级（iOS label / secondary / tertiary / quaternary）

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.92)
    static let textTertiary = Color.white.opacity(0.60)
    static let textQuaternary = Color.white.opacity(0.30)

    // MARK: - 卡片材质（实色，不用半透明）

    static let glassBackground = cardBackground
    static let glassStroke = separator
    static let glassHighlight = Color.white.opacity(0.06)

    // MARK: - 字体

    /// 数字用等宽字体，避免延迟/电平数值跳动
    static func monoFont(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func displayFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
}

// MARK: - 视图修饰器

/// iOS 分组卡片容器。
///
/// ★ 与上一版「液态玻璃」的三点不同：
///   ① 圆角 20 → 14（iOS 的 cardRadius 就是 10~14pt，20 显得圆得过头）
///   ② **去掉大阴影** —— iOS 靠背景色差（黑 vs #1C1C1E）分层，
///      16pt 的黑阴影在 OLED 上会让卡片边缘糊成一圈灰，
///      是「不够精致」的最大来源
///   ③ 顶部高光从 18% 白降到 6% —— 原值在纯黑底上会看到一条明显的亮边，
///      像塑料反光而不是玻璃
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 14
    var padding: CGFloat = 16
    /// 顶部高光，营造玻璃厚度感（苹果风下很淡）
    var showHighlight: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(KaraokeTheme.glassBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(KaraokeTheme.glassStroke, lineWidth: 0.5)
                    }
            }
            .overlay(alignment: .top) {
                if showHighlight {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [KaraokeTheme.glassHighlight, .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .frame(height: cornerRadius * 0.6)
                        .mask {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        }
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 14,
                   padding: CGFloat = 16,
                   showHighlight: Bool = true) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius,
                           padding: padding,
                           showHighlight: showHighlight))
    }
}

/// 状态色映射：延迟等级。
enum LatencyQuality {
    static func color(for ms: Float) -> Color {
        switch ms {
        case ..<60:   return KaraokeTheme.latencyGood
        case ..<110:  return KaraokeTheme.latencyFair
        default:      return KaraokeTheme.latencyPoor
        }
    }

    static func label(for ms: Float) -> String {
        switch ms {
        case ..<60:   return "优秀"
        case ..<110:  return "良好"
        case ..<180:  return "偏高"
        default:      return "过高"
        }
    }
}

/// dBFS 转 0~1 的可视化比例。
func levelToNormalized(_ db: Float) -> CGFloat {
    // -60dB ~ 0dB 映射到 0~1
    let clamped = max(-60, min(0, db))
    return CGFloat((clamped + 60) / 60)
}
