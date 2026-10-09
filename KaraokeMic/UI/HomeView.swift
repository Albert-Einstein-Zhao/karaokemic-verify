//
//  HomeView.swift
//  雪宝 K歌麦克风 · iOS 端 · 主控台
//
//  这是 App 打开后的第一屏，也是唱歌时最常看的一屏。
//  设计目标：一屏之内看清「连接状态 / 电平 / 延迟 / 录音开关」，不用滚动。
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        ZStack {
            KaraokeTheme.bgGradient.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    statusHeader
                    mainControlArea
                    metricsRow
                    quickPresets
                    warningBanner
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - 状态头

    private var statusHeader: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    StatusDot(
                        color: app.connectionColor,
                        isAnimating: app.network.state == .ready
                    )
                    Text(app.network.state.displayText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer()

                if let device = app.connectedDevice {
                    Text(device.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.top, 4)

            Text("雪宝 K歌麦")
                .font(KaraokeTheme.displayFont(28))
                .foregroundStyle(.white)
        }
    }

    // MARK: - 主控制区（麦克风按钮 + 电平表）

    private var mainControlArea: some View {
        HStack(alignment: .center, spacing: 20) {
            // 左侧电平表
            VStack(spacing: 8) {
                LevelMeter(
                    levelDb: app.audio.currentLevelDb,
                    peakDb: app.audio.peakLevelDb,
                    height: 190,
                    width: 12
                )
                Text("电平")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }

            Spacer(minLength: 0)

            // 中央麦克风按钮
            MicButton(
                isConnected: app.network.state == .ready,
                isRecording: app.isRecording,
                isHowling: app.audio.howlingDetected,
                level: levelToNormalized(app.audio.currentLevelDb)
            ) {
                app.toggleRecording()
            }

            Spacer(minLength: 0)

            // 右侧：波形历史 + 状态指示
            VStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 4) {
                    if app.audio.isSinging {
                        Label("演唱中", systemImage: "music.note")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(KaraokeTheme.success)
                    } else {
                        Label("待唱", systemImage: "mic")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    if app.audio.howlingDetected {
                        Label("啸叫", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(KaraokeTheme.danger)
                    }
                }
                .frame(width: 90, alignment: .trailing)

                // 纵向波形历史
                WaveformHistory(levels: app.audio.levels, barWidth: 2, spacing: 2)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 60, height: 60)
                    .opacity(0.6)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - 指标行

    private var metricsRow: some View {
        HStack(spacing: 10) {
            MetricCard(
                label: "端到端延迟",
                value: String(format: "%.0f", app.latencyMs),
                unit: "ms",
                tint: LatencyQuality.color(for: app.latencyMs),
                icon: "speedometer"
            )

            MetricCard(
                label: "回声消除",
                value: String(format: "%.0f", app.audio.erleDb),
                unit: "dB",
                tint: app.audio.erleDb > 8 ? KaraokeTheme.success : KaraokeTheme.warning,
                icon: "waveform.badge.minus"
            )

            MetricCard(
                label: "盒子电平",
                value: app.network.boxAudioLevelDb <= -100
                    ? "—" : String(format: "%.0f", app.network.boxAudioLevelDb),
                unit: "dB",
                tint: KaraokeTheme.accentCyan,
                icon: "hifispeaker.2"
            )
        }
    }

    // MARK: - 快速预设

    private var quickPresets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("演唱模式")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))

            HStack(spacing: 10) {
                ForEach(PerformMode.allCases) { mode in
                    Button {
                        app.applyPerformMode(mode)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 18))
                            Text(mode.displayName)
                                .font(.system(size: 11, weight: .medium))
                            Text(mode.subtitle)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(app.activeMode == mode
                                      ? KaraokeTheme.accentGradient.opacity(0.35)
                                      : Color.white.opacity(0.05))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(
                                            app.activeMode == mode
                                                ? KaraokeTheme.accentCyan.opacity(0.6)
                                                : Color.white.opacity(0.1),
                                            lineWidth: 0.5)
                                }
                        }
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 警告横幅

    @ViewBuilder
    private var warningBanner: some View {
        if app.audio.howlingDetected {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(KaraokeTheme.danger)

                VStack(alignment: .leading, spacing: 2) {
                    Text("检测到啸叫")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(KaraokeTheme.danger)
                    Text("正在自动压制。也可调低输入增益或后退一步。")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(KaraokeTheme.danger.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(KaraokeTheme.danger.opacity(0.4), lineWidth: 0.5)
                    }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }

        if app.network.underruns > 5 {
            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(KaraokeTheme.warning)

                VStack(alignment: .leading, spacing: 2) {
                    Text("网络不稳定")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(KaraokeTheme.warning)
                    Text("盒子已发生 \(app.network.underruns) 次欠载，建议靠近路由器或改用 5GHz")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(KaraokeTheme.warning.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(KaraokeTheme.warning.opacity(0.4), lineWidth: 0.5)
                    }
            }
        }
    }
}

// MARK: - 演唱模式

/// 一键切换整套参数预设。
enum PerformMode: String, CaseIterable, Identifiable {
    case standard// 标准
    case lively        // 热闹（强混响）
    case studio        // 录音棚（干声+压缩）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "标准"
        case .lively:   return "热闹"
        case .studio:   return "录音棚"
        }
    }

    var subtitle: String {
        switch self {
        case .standard: return "均衡"
        case .lively:   return "带感"
        case .studio:   return "清晰"
        }
    }

    var icon: String {
        switch self {
        case .standard: return "slider.horizontal.3"
        case .lively:   return "sparkles"
        case .studio:   return "waveform.path.ecg"
        }
    }

    var parameters: SignalParameters {
        var p = SignalParameters.default
        switch self {
        case .standard:
            p.reverbPreset = .smallRoom
            p.reverbWet = 0.12
            p.compThresholdDb = -18
            p.compRatio = 3.0
            p.eqLowDb = 0; p.eqMidDb = 0; p.eqHighDb = 0
        case .lively:
            p.reverbPreset = .stage
            p.reverbWet = 0.22
            p.compThresholdDb = -22
            p.compRatio = 4.0
            p.eqLowDb = 2; p.eqMidDb = 1; p.eqHighDb = 3
        case .studio:
            p.reverbPreset = .dry
            p.reverbWet = 0.03
            p.compThresholdDb = -14
            p.compRatio = 5.0
            p.eqLowDb = -1; p.eqMidDb = 0; p.eqHighDb = 1
        }
        return p
    }
}
