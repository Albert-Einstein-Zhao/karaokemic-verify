//
//  DeviceView.swift
//  雪宝 K歌麦克风 · iOS 端 · 设备连接
//

import SwiftUI

struct DeviceView: View {
    @EnvironmentObject var app: AppViewModel
    @State private var manualIP = ""
    @State private var showManualInput = false

    var body: some View {
        ZStack {
            KaraokeTheme.bgGradient.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    if app.network.discoveredDevices.isEmpty {
                        emptyState
                    } else {
                        deviceList
                    }

                    manualEntry
                    diagnosticsCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("设备")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(KaraokeTheme.bgTop, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            if app.network.discoveredDevices.isEmpty {
                app.network.startDiscovery()
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(KaraokeTheme.accentGlow)
                    .frame(width: 160, height: 160)
                    .blur(radius: 24)

                Image(systemName: app.network.state == .discovering
                      ? "antenna.radiowaves.left.and.right"
                      : "tv.badge.wifi")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(KaraokeTheme.accentCyan)
                    .symbolEffectIfAvailable(
                        active: app.network.state == .discovering)
            }

            VStack(spacing: 6) {
                Text(app.network.state == .discovering ? "正在扫描局域网…" : "没找到盒子？")
                    .font(KaraokeTheme.displayFont(18))
                    .foregroundStyle(.white)

                Text("确认 iPhone 和极光盒子连的是同一个 Wi-Fi")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }

            if app.network.state != .discovering {
                Button("重新扫描") {
                    app.network.startDiscovery()
                }
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background {
                    Capsule().fill(KaraokeTheme.accentGradient)
                }
                .foregroundStyle(.white)
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - 设备列表

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("发现的设备")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("\(app.network.discoveredDevices.count) 台")
                    .font(KaraokeTheme.monoFont(11))
                    .foregroundStyle(.white.opacity(0.4))
            }

            ForEach(app.network.discoveredDevices) { device in
                Button {
                    app.connect(to: device)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "tv.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(KaraokeTheme.accentCyan)
                            .frame(width: 36)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                            Text("\(device.ip):\(device.port)  ·  v\(device.appVersion)")
                                .font(KaraokeTheme.monoFont(11))
                                .foregroundStyle(.white.opacity(0.45))
                        }

                        Spacer()

                        if app.connectedDevice?.id == device.id {
                            StatusDot(color: KaraokeTheme.success, isAnimating: true)
                            Text("已连接")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(KaraokeTheme.success)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    .padding(14)
                    .background {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(app.connectedDevice?.id == device.id
                                  ? KaraokeTheme.success.opacity(0.12)
                                  : Color.white.opacity(0.05))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(
                                        app.connectedDevice?.id == device.id
                                            ? KaraokeTheme.success.opacity(0.4)
                                            : Color.white.opacity(0.08),
                                        lineWidth: 0.5)
                            }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .glassCard()
    }

    // MARK: - 手动输入

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("手动连接")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button {
                    withAnimation { showManualInput.toggle() }
                } label: {
                    Image(systemName: showManualInput ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                        .foregroundStyle(KaraokeTheme.accentCyan)
                }
            }

            if showManualInput {
                VStack(spacing: 10) {
                    TextField("192.168.1.23", text: $manualIP)
                        .font(KaraokeTheme.monoFont(14))
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.07))
                        }
                        .foregroundStyle(.white)

                    Button("连接") {
                        let ip = manualIP.trimmingCharacters(in: .whitespaces)
                        guard !ip.isEmpty else { return }
                        app.network.connectManually(ip: ip)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(KaraokeTheme.accentGradient)
                    }
                    .foregroundStyle(.white)
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glassCard()
    }

    // MARK: - 诊断卡

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("链路诊断")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }

            diagnosticRow("连接状态", app.network.state.displayText,
                         tint: app.connectionColor)
            diagnosticRow("往返延迟 RTT",
                         app.network.roundTripMs > 0
                         ? String(format: "%.1f ms", app.network.roundTripMs) : "—",
                         tint: LatencyQuality.color(for: app.latencyMs))
            diagnosticRow("盒子缓冲深度",
                         String(format: "%.0f ms", app.network.bufferFillMs),
                         tint: .white)
            diagnosticRow("盒子系统音量",
                         "\(app.network.boxSystemVolume)",
                         tint: .white)
            diagnosticRow("已发送数据包", "\(app.network.packetsSent)",
                         tint: .white)
            diagnosticRow("盒子欠载次数", "\(app.network.underruns)",
                         tint: app.network.underruns > 5
                         ? KaraokeTheme.warning : KaraokeTheme.success)

            Divider().overlay(Color.white.opacity(0.1))

            Text("如果延迟偏高，先检查：")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))

            ForEach([
                "① iPhone 与盒子是否在同一 Wi-Fi（别用访客网络）",
                "② 5GHz 频段比 2.4GHz 延迟低约 30%",
                "③ 盒子上把「混音室 → 混响量」调低会增加处理延迟",
                "④ 关闭其他占用 Wi-Fi 的设备（摄像头投流等）"
            ], id: \.self) { tip in
                Text(tip)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .glassCard()
    }

    private func diagnosticRow(_ label: String, _ value: String, tint: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(value)
                .font(KaraokeTheme.monoFont(12))
                .foregroundStyle(tint)
        }
    }
}
