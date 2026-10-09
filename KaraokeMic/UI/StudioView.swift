//
//  StudioView.swift
//  雪宝 K歌麦克风 · iOS 端 · 混音室
//
//  这里是你要求的「混响 + 回声消除 + 各路调节」的控制面板。
//  所有效果在 iPhone 本地处理 —— 零网络往返延迟。
//

import SwiftUI

struct StudioView: View {
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        ZStack {
            KaraokeTheme.bgGradient.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    // 顶部频谱可视化
                    spectrumHeader
                    // 回声消除区
                    aecSection
                    // 混响区（你要求的核心功能）
                    reverbSection
                    // 啸叫抑制
                    howlingSection
                    // EQ
                    eqSection
                    // 动态处理
                    dynamicsSection
                    // 音量分区
                    volumeSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("混音室")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(KaraokeTheme.bgTop, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - 频谱头

    private var spectrumHeader: some View {
        VStack(spacing: 10) {
            SpectrumView(level: levelToNormalized(app.audio.currentLevelDb))

            HStack {
                Text("实时输入")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Text(String(format: "%.1f dB", app.audio.currentLevelDb))
                    .font(KaraokeTheme.monoFont(11))
                    .foregroundStyle(KaraokeTheme.accentCyan)
            }
        }
        .glassCard(cornerRadius: 18, padding: 14)
        .padding(.top, 8)
    }

    // MARK: - 回声消除

    private var aecSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("回声消除",
                          icon: "waveform.badge.minus",
                          tint: KaraokeTheme.accentCyan)

            ToggleRow(title: "启用回声消除",
                      subtitle: "消除自己人声的回灌，参考信号 = 本机发出的 PCM",
                      isOn: $app.params.aecEnabled)

            ParameterSlider(
                title: "消除强度",
                value: $app.params.aecStrength,
                range: 0...1,
                tint: KaraokeTheme.accentCyan
            ) {
                String(format: "%.0f%%", $0 * 100)
            }

            // 实时 ERLE 展示
            HStack(spacing: 8) {
                Text("残余回声")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text(String(format: "%.1f dB", app.audio.erleDb))
                    .font(KaraokeTheme.monoFont(12))
                    .foregroundStyle(app.audio.erleDb > 8
                                     ? KaraokeTheme.success : KaraokeTheme.warning)
            }

            // 双讲指示
            if app.audio.isSinging {
                HStack(spacing: 6) {
                    StatusDot(color: KaraokeTheme.success, size: 6)
                    Text("检测到演唱 · 已冻结系数更新以防误消除")
                        .font(.system(size: 10))
                        .foregroundStyle(KaraokeTheme.success.opacity(0.85))
                }
            }
        }
        .glassCard()
    }

    // MARK: - 混响（你要求的功能）

    /// 单个混响预设胶囊。
    /// ★ 单独抽成方法：原来内联在 ForEach 里，Swift 编译器类型检查超时
    ///   （CI 首次编译报 "unable to type-check in reasonable time"）。
    ///   顺带把 fill 的三元改用 AnyShapeStyle 包 —— LinearGradient 与 Color
    ///   是不同类型，裸三元本身也是拖慢类型检查的元凶。
    private func reverbPresetChip(_ preset: ReverbPreset) -> some View {
        let selected = app.params.reverbPreset == preset
        return Button {
            app.params.reverbPreset = preset
            let p = preset.parameters
            app.params.reverbWet = p.wet
            app.params.reverbDamping = p.damping
            app.params.reverbRoomSize = p.roomSize
            app.params.reverbWidth = p.width
        } label: {
            VStack(spacing: 3) {
                Text(preset.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(preset.subtitle)
                    .font(.system(size: 9))
                    .opacity(0.6)
            }
            .frame(minWidth: 66)
            .padding(.vertical, 9)
            .background {
                let style: AnyShapeStyle = selected
                    ? AnyShapeStyle(KaraokeTheme.accentGradient)
                    : AnyShapeStyle(Color.white.opacity(0.07))
                Capsule().fill(style)
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    private var reverbSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("混响效果",
                          icon: "wind",
                          tint: KaraokeTheme.accentPurple)

            // 预设胶囊
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReverbPreset.allCases) { preset in
                        reverbPresetChip(preset)
                    }
                }
                .padding(.horizontal, 1)
            }

            // 干声预设时不显示调节项（省空间 + 避免误解）
            if app.params.reverbWet > 0.005 {
                VStack(spacing: 10) {
                    ParameterSlider(
                        title: "混响量",
                        value: $app.params.reverbWet,
                        range: 0...0.4,
                        step: 0.005,
                        tint: KaraokeTheme.accentPurple
                    ) {
                        String(format: "%.0f%%", $0 * 100)
                    }

                    ParameterSlider(
                        title: "空间尺寸",
                        value: $app.params.reverbRoomSize,
                        tint: KaraokeTheme.accentPurple
                    ) {
                        roomSizeLabel($0)
                    }

                    ParameterSlider(
                        title: "高频阻尼",
                        value: $app.params.reverbDamping,
                        tint: KaraokeTheme.accentPurple
                    ) {
                        $0 < 0.4 ? "亮" : ($0 < 0.7 ? "自然" : "闷")
                    }

                    ParameterSlider(
                        title: "立体声宽度",
                        value: $app.params.reverbWidth,
                        tint: KaraokeTheme.accentPurple
                    ) {
                        String(format: "%.0f%%", $0 * 100)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // 监听开关
            ToggleRow(title: "本机监听",
                      subtitle: "耳机里听到自己处理后的声音（判断唱准）",
                      isOn: $app.monitoringEnabled,
                      tint: KaraokeTheme.accentPurple)
        }
        .glassCard()
    }

    // MARK: - 啸叫抑制

    private var howlingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("啸叫抑制",
                          icon: "exclamationmark.triangle",
                          tint: KaraokeTheme.warning)

            ToggleRow(title: "启用啸叫抑制",
                      subtitle: "自动陷波压制正反馈",
                      isOn: $app.params.howlingSuppressionEnabled,
                      tint: KaraokeTheme.warning)

            ParameterSlider(
                title: "抑制强度",
                value: $app.params.howlingStrength,
                tint: KaraokeTheme.warning
            ) {
                String(format: "%.0f%%", $0 * 100)
            }

            if app.audio.howlingDetected {
                HStack(spacing: 6) {
                    StatusDot(color: KaraokeTheme.danger, size: 6, isAnimating: true)
                    Text("检测到 \(app.audio.howlingFrequencies.map { String(format: "%.0f", $0) }.joined(separator: " / ")) Hz")
                        .font(KaraokeTheme.monoFont(10))
                        .foregroundStyle(KaraokeTheme.danger)
                }
            }
        }
        .glassCard()
    }

    // MARK: - EQ

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("音色 EQ", icon: "slider.vertical.3", tint: .white.opacity(0.8))

            ParameterSlider(title: "低频 100Hz",
                            value: $app.params.eqLowDb,
                            range: -12...12,
                            step: 0.5,
                            tint: KaraokeTheme.warning) {
                String(format: "%+.1f dB", $0)
            }

            ParameterSlider(title: "中频 1kHz",
                            value: $app.params.eqMidDb,
                            range: -12...12,
                            step: 0.5,
                            tint: KaraokeTheme.accentCyan) {
                String(format: "%+.1f dB", $0)
            }

            ParameterSlider(title: "高频 8kHz",
                            value: $app.params.eqHighDb,
                            range: -12...12,
                            step: 0.5,
                            tint: KaraokeTheme.success) {
                String(format: "%+.1f dB", $0)
            }
        }
        .glassCard()
    }

    // MARK: - 动态处理

    private var dynamicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("动态处理", icon: "dial.high.fill", tint: .white.opacity(0.8))

            ToggleRow(title: "压缩器",
                      subtitle: "防止喊破音产生削波失真",
                      isOn: $app.params.compressorEnabled,
                      tint: .white.opacity(0.8))

            ParameterSlider(title: "输入增益",
                            value: $app.params.inputGainDb,
                            range: -20...20,
                            step: 0.5,
                            unit: " dB",
                            tint: KaraokeTheme.accentCyan) {
                String(format: "%+.1f", $0)
            }

            ParameterSlider(title: "压缩阈值",
                            value: $app.params.compThresholdDb,
                            range: -40...0,
                            step: 1,
                            unit: " dB",
                            tint: .white.opacity(0.8)) {
                String(format: "%.0f", $0)
            }

            ParameterSlider(title: "压缩比",
                            value: $app.params.compRatio,
                            range: 1...10,
                            step: 0.5,
                            tint: .white.opacity(0.8)) {
                    String(format: "%.1f:1", $0)
                }

            ToggleRow(title: "高通滤波 80Hz",
                      subtitle: "切掉空调声、桌面震动等低频噪声",
                      isOn: $app.params.highPassEnabled)
        }
        .glassCard()
    }

    // MARK: - 音量分区

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("音量分配", icon: "speaker.wave.3.fill",
                          tint: KaraokeTheme.accentCyan)

            Text("「人声」在盒子端独立控制，不影响伴奏。伴奏音量请在 K歌 App 或盒子系统音量中调节。")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 14) {
                volumeSlider(title: "人声（麦克风）",
                             icon: "mic.fill",
                             tint: KaraokeTheme.accentCyan,
                             value: $app.boxVolume)

                volumeSlider(title: "伴奏（在 K歌 App 调）",
                             icon: "music.note",
                             tint: KaraokeTheme.accentPurple,
                             value: $app.accompanimentVolume,
                             isReadOnly: true)
            }

            HStack(spacing: 10) {
                Button {
                    app.setBoxMuted(true)
                } label: {
                    Label("静音人声", systemImage: "mic.slash.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(KaraokeTheme.danger.opacity(0.2))
                        }
                        .foregroundStyle(KaraokeTheme.danger)
                }
                .buttonStyle(.plain)

                Button {
                    app.setBoxMuted(false)
                } label: {
                    Label("恢复", systemImage: "mic.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(KaraokeTheme.success.opacity(0.2))
                        }
                        .foregroundStyle(KaraokeTheme.success)
                }
                .buttonStyle(.plain)
            }
        }
        .glassCard()
    }

    // MARK: - 辅助视图

    private func sectionHeader(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
        }
    }

    private func volumeSlider(title: String,
                              icon: String,
                              tint: Color,
                              value: Binding<Float>,
                              isReadOnly: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(String(format: "%.0f%%", value.wrappedValue * 100))
                    .font(KaraokeTheme.monoFont(12))
                    .foregroundStyle(tint)
            }

            if isReadOnly {
                // 只读展示
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(KaraokeTheme.accentGradient)
                            .frame(width: geo.size.width * CGFloat(value.wrappedValue))
                    }
                }
                .frame(height: 6)
            } else {
                Slider(value: value, in: 0...1)
                    .tint(tint)
            }
        }
    }

    private func roomSizeLabel(_ v: Float) -> String {
        switch v {
        case ..<0.3: return "紧凑"
        case ..<0.6: return "适中"
        case ..<0.85: return "宽敞"
        default: return "巨大"
        }
    }
}
