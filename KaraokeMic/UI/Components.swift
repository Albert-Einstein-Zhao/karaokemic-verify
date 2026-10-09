//
//  Components.swift
//  雪宝 K歌麦克风 · iOS 端
//
//  可复用 UI 组件：液态麦克风按钮、电平表、频谱波形、参数滑块。
//

import SwiftUI

// MARK: - 液态麦克风按钮（主控台核心视觉）

/// 中央大麦克风按钮。
/// 连接状态不同：灰色禁用 /青色呼吸 / 红色警告（啸叫）
struct MicButton: View {
    var isConnected: Bool
    var isRecording: Bool
    var isHowling: Bool
    var level: CGFloat           // 0~1 音量
    var action: () -> Void

    @State private var pulse = false

    private var ringColor: Color {
        if isHowling { return KaraokeTheme.danger }
        if isRecording { return KaraokeTheme.accentCyan }
        if isConnected { return KaraokeTheme.accentPurple }
        return Color.gray.opacity(0.5)
    }

    var body: some View {
        ZStack {
            // 外层辉光（随音量呼吸）
            Circle()
                .fill(KaraokeTheme.accentGlow)
                .frame(width: 260 * (0.9 + level * 0.35), height: 260 * (0.9 + level * 0.35))
                .blur(radius: 30)
                .opacity(isRecording ? 0.7 : 0)
                .scaleEffect(pulse ? 1.08 : 1.0)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                          value: pulse)

            // 主圆
            Circle()
                .fill(
                    LinearGradient(
                        colors: isRecording
                            ? [KaraokeTheme.accentCyan.opacity(0.9), KaraokeTheme.accentPurple.opacity(0.9)]
                            : [Color.white.opacity(0.12), Color.white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 190, height: 190)
                .overlay {
                    Circle().strokeBorder(ringColor.opacity(0.8), lineWidth: 2)
                }
                .overlay {
                    // 顶部高光（玻璃厚度）
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .frame(width: 150, height: 110)
                        .offset(y: -38)
                        .mask(Circle())
                        .allowsHitTesting(false)
                }
                .shadow(color: ringColor.opacity(0.6), radius: 30)

            // 麦克风图标
            Image(systemName: isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(isRecording ? Color.white : Color.white.opacity(0.7))
                .symbolEffectIfAvailable(active: isRecording)
        }
        .scaleEffect(isRecording ? 1.0 + level * 0.06 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: level)
        .opacity(isConnected ? 1.0 : 0.5)
        .onTapGesture {
            if isConnected { action() }
        }
        .onAppear { pulse = true }
        .accessibilityLabel(isRecording ? "停止收音" : "开始收音")
        .accessibilityHint(isConnected ? "" : "请先连接电视盒子")
    }
}

// MARK: - 电平表

/// 竖向电平表（主控台右侧）。
struct LevelMeter: View {
    var levelDb: Float
    var peakDb: Float
    var height: CGFloat = 200
    var width: CGFloat = 14

    private var normalized: CGFloat { levelToNormalized(levelDb) }
    private var peakNormalized: CGFloat { levelToNormalized(peakDb) }

    private var levelColor: Color {
        if levelDb > -3 { return KaraokeTheme.danger }
        if levelDb > -12 { return KaraokeTheme.warning }
        return KaraokeTheme.success
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // 轨道
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                }

            // 电平条
            GeometryReader { geo in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 7)
                        .fill(
                            LinearGradient(
                                colors: [KaraokeTheme.success, KaraokeTheme.warning,
                                         KaraokeTheme.danger],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(height: geo.size.height * normalized)
                        .animation(.linear(duration: 0.08), value: normalized)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))

            // 峰值保持线
            GeometryReader { geo in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(height: 2)
                        .offset(y: -geo.size.height * peakNormalized)
                        .animation(.easeOut(duration: 0.3), value: peakNormalized)
                }
            }

            // 刻度
            VStack {
                Text("0").font(KaraokeTheme.monoFont(8)).foregroundStyle(.white.opacity(0.35))
                Spacer()
                Text("-24").font(KaraokeTheme.monoFont(8)).foregroundStyle(.white.opacity(0.35))
                Spacer()
                Text("-48").font(KaraokeTheme.monoFont(8)).foregroundStyle(.white.opacity(0.35))
            }
            .offset(x: width / 2 + 12)
        }
        .frame(width: width, height: height)
    }
}

// MARK: - 波形历史（横条）

/// 最近音频电平的波形条。
struct WaveformHistory: View {
    var levels: [Float]
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, db in
                let norm = levelToNormalized(db)
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(
                        LinearGradient(
                            colors: [KaraokeTheme.accentPurple, KaraokeTheme.accentCyan],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: barWidth, height: max(norm * 60, 3))
                    .opacity(0.35 + Double(index) / Double(levels.count) * 0.65)
            }
        }
        .animation(.linear(duration: 0.1), value: levels)
    }
}

// MARK: - 频谱可视化（混响/效果页）

/// 实时频谱柱状图（iOS 端用波形近似，Android 端有真FFT）。
struct SpectrumView: View {
    var level: CGFloat
    var barCount: Int = 28

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                // 用 sin 造一个伪频谱形状，随音量缩放
                let phase = Double(i) / Double(barCount)
                let shape = (sin(phase * .pi * 3) * 0.5 + 0.5)
                let noise = CGFloat.random(in: 0.85...1.15)
                let height = max(level * shape * noise * 90, 4)

                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [KaraokeTheme.accentCyan, KaraokeTheme.accentPurple],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 4, height: height)
                    .opacity(0.5 + level * 0.5)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

// MARK: - 参数滑块（带数值显示）

/// 带标签和数值的滑块。
struct ParameterSlider: View {
    var title: String
    @Binding var value: Float
    var range: ClosedRange<Float> = 0...1
    var step: Float = 0.01
    var unit: String = ""
    var tint: Color = KaraokeTheme.accentCyan
    var valueFormat: (Float) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(valueFormat(value) + unit)
                    .font(KaraokeTheme.monoFont(13))
                    .foregroundStyle(tint)
            }

            Slider(value: Binding(
                get: { Double(value) },
                set: { value = Float($0) }
            ), in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
            .tint(tint)
        }
    }
}

// MARK: - 开关行

struct ToggleRow: View {
    var title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var tint: Color = KaraokeTheme.accentCyan

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(tint)
        }
    }
}

// MARK: - 状态指示点

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8
    var isAnimating: Bool = false

    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.8), radius: 6)
            .scaleEffect(isAnimating && animate ? 1.4 : 1.0)
            .opacity(isAnimating && animate ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                       value: animate)
            .onAppear { animate = true }
    }
}

// MARK: - 指标小卡

struct MetricCard: View {
    var label: String
    var value: String
    var unit: String = ""
    var tint: Color = .white
    var icon: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundStyle(tint.opacity(0.7))
                }
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(KaraokeTheme.monoFont(20, weight: .semibold))
                    .foregroundStyle(tint)
                if !unit.isEmpty {
                    Text(unit)
                        .font(KaraokeTheme.monoFont(10))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14, padding: 12)
    }
}

// MARK: - iOS 17 symbolEffect 的安全降级

/**
 * `symbolEffect(.variableColor...)` 是 **iOS 17.0+** API，
 * 而 App 的 deploymentTarget 是 16.0 —— 直接调用编译不过
 * （CI 首次编译在 Components/DeviceView 各抓出一处）。
 *
 * 做成 ViewModifier + #available：iOS 17 上有波形流动动画，
 * iOS 16 上静默降级为静态图标 —— 功能不缺，只是少了层动效。
 */
private struct SymbolEffectIfAvailable: ViewModifier {
    var isActive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.symbolEffect(.variableColor.iterative, isActive: isActive)
        } else {
            content
        }
    }
}

extension View {
    func symbolEffectIfAvailable(active: Bool) -> some View {
        modifier(SymbolEffectIfAvailable(isActive: active))
    }
}
