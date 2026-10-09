//
//  SettingsView.swift
//  雪宝 K歌麦克风 · iOS 端 · 设置
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        ZStack {
            KaraokeTheme.bgGradient.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    audioSection
                    latencySection
                    aboutSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(KaraokeTheme.bgTop, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - 音频设置

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                    .foregroundStyle(KaraokeTheme.accentCyan)
                Text("音频")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }

            settingRow("采样率", value: "48000 Hz", subtitle: "设备原生，无重采样")
            settingRow("采样格式", value: "PCM S16LE", subtitle: "零编解码延迟")
            settingRow("声道", value: "单声道", subtitle: "麦克风原生")
            settingRow("每包帧长", value: "20 ms", subtitle: "延迟与抗丢包的平衡点")
            settingRow("传输协议", value: "UDP", subtitle: "局域网低延迟首选")
        }
        .glassCard()
    }

    // MARK: - 延迟设置

    private var latencySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "speedometer")
                    .foregroundStyle(LatencyQuality.color(for: app.latencyMs))
                Text("延迟")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: "%.0f ms", app.latencyMs))
                    .font(KaraokeTheme.monoFont(14))
                    .foregroundStyle(LatencyQuality.color(for: app.latencyMs))
            }

            ParameterSlider(
                title: "延迟补偿",
                value: $app.latencyCompensationMs,
                range: 0...300,
                step: 5,
                unit: " ms",
                tint: LatencyQuality.color(for: app.latencyMs)
            ) {
                String(format: "%.0f", $0)
            }

            Text("延迟补偿用于对齐电视画面的声音。唱歌感觉「慢半拍」时，往右调；感觉「抢拍」往左调。")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Color.white.opacity(0.1))

            // 延迟构成拆解 —— 让用户知道延迟花在哪
            VStack(alignment: .leading, spacing: 6) {
                Text("延迟构成")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))

                breakdownRow("网络传输", app.network.roundTripMs / 2)
                breakdownRow("盒子缓冲", app.network.bufferFillMs)
                breakdownRow("盒子输出", 20)
                Divider().overlay(Color.white.opacity(0.08))
                breakdownRow("合计", app.latencyMs, isTotal: true)
            }
        }
        .glassCard()
    }

    // MARK: - 关于

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.white.opacity(0.7))
                Text("关于")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("雪宝 K歌麦")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("版本 1.0.0")
                        .font(KaraokeTheme.monoFont(11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Image(systemName: "mic.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(KaraokeTheme.accentGradient)
            }

            Divider().overlay(Color.white.opacity(0.1))

            VStack(alignment: .leading, spacing: 8) {
                Text("技术说明")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))

                Text("""
                · 局域网 UDP 直传，不经过互联网，不经过蓝牙
                · 盒子端利用 Android 系统级混音，伴奏与人声自动叠加
                · 人声音量独立控制，不影响盒子其他 App
                · 回声消除采用 NLMS 自适应滤波，参考信号为本机发出的 PCM
                · 所有效果（混响/EQ/压缩/啸叫抑制）在 iPhone 本地处理，零网络延迟
                """)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Color.white.opacity(0.1))

            // 免责声明
            Text("""
            ⚠️ 关于啸叫：本App 可消除「你自己人声」被电视喇叭回灌的部分。
            盒子 K歌 App 的伴奏漏回无法完全消除（iPhone 拿不到伴奏信号）。
            若仍啸叫，请：①降低输入增益 ②后退一步让麦克风背对电视 ③加防喷罩 ④使用混音室→监听模式改用有线耳机。
            """)
            .font(.system(size: 10))
            .foregroundStyle(KaraokeTheme.warning.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()
    }

    // MARK: - 辅助

    private func settingRow(_ label: String, value: String, subtitle: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Text(value)
                .font(KaraokeTheme.monoFont(12))
                .foregroundStyle(KaraokeTheme.accentCyan)
        }
    }

    private func breakdownRow(_ label: String, _ ms: Float, isTotal: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: isTotal ? 12 : 11,
                              weight: isTotal ? .semibold : .regular))
                .foregroundStyle(.white.opacity(isTotal ? 0.9 : 0.5))
            Spacer()
            Text(String(format: "%.0f ms", ms))
                .font(KaraokeTheme.monoFont(isTotal ? 12 : 11))
                .foregroundStyle(isTotal ? KaraokeTheme.accentCyan : .white.opacity(0.6))
        }
    }
}
