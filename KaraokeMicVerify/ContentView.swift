//
//  ContentView.swift
//  雪宝 K歌麦克风 · 极简验证版
//
//  单屏界面，目的只有一个：**验证 DSP 与延迟**，不做任何视觉包装。
//
//  显示的6 个关键指标（决定了「这方案能不能成」）：
//  1. 连接状态 +盒子名
//  2. 端到端延迟（RTT/2 + 盒子缓冲 + 输出）—— 对标蓝牙 150-300ms
//  3. AEC 效果（ERLE dB，越高越好；> 10dB 算有效）
//  4. 啸叫检测（有无 + 频率）
//  5. 输入电平（看有没有拾到音）
//  6. 已发帧数（确认真的在发）
//
//  顶部 4 个开关：直接调 DSP 参数，用来现场找最优值。
//

import SwiftUI

struct ContentView: View {
    // ★ 从 App 层注入（第 18 轮改成 @EnvironmentObject）
    //
    //   原来这里自己 @StateObject 创建 VerifyViewModel，
    //   App 层的 onAppear 里就拿不到同一个实例，自动发现无法启动。
    //   改成由 App 创建并通过 environmentObject 传下来，
    //   保证「扫描发现的设备」和「界面显示的状态」是同一份数据。
    @EnvironmentObject private var vm: VerifyViewModel

    var body: some View {
        ZStack {
            Color(red: 0.043, green: 0.055, blue: 0.090)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header

                    // ── IP 输入 + 连接 ──
                    ipSection

                    // ── 错误提示（权限被拒/ 引擎启动失败等）──
                    if let msg = vm.errorMessage {
                        errorBanner(msg)
                    }

                    // ── 关键指标 ──
                    if vm.isNetworkReady {
                        metricsSection
                        waveformSection
                        controlsSection
                    } else {
                        disconnectedHint
                    }

                    Spacer(minLength: 20)
                }
                .padding(20)
            }
        }
    }

    // MARK: - 错误提示

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 15))

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.4), lineWidth: 0.5)
        )
    }

    // ══════════════════════════════════════════════════════════════

    private var header: some View {
        VStack(spacing: 4) {
            Text("K歌麦克风 · 验证版")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("iPhone → 局域网 → 极光盒子")
                .font(.system(size: 12))
                .foregroundStyle(.gray)
        }
        .padding(.top, 10)
    }

    /// 输入框里的 IP 是否是合法的四段数字（1~254）
    private var boxIPIsValid: Bool {
        let parts = vm.boxIP.split(separator: ".")
        guard parts.count == 4 else { return false }
        for p in parts {
            guard let v = Int(p), v >= 0, v <= 255 else { return false }
        }
        return true
    }

    private var ipSection: some View {
        VStack(spacing: 12) {
            HStack {
                // ★ placeholder 会随扫描状态变：没填时提示「自动扫描中…」，
                //   用户一眼就知道该等还是该手填（第二十三轮）
                TextField(vm.boxIP.isEmpty ? "自动扫描盒子…" : "盒子 IP",
                          text: $vm.boxIP)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, design: .monospaced))
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .onChange(of: vm.boxIP) { _ in
                        // 用户手动改过 → 之后不再被自动扫描结果覆盖
                        vm.markIPManuallyEdited()
                    }

                Button {
                    if vm.isConnected {
                        vm.disconnect()
                    } else {
                        vm.connect(boxIP: vm.boxIP)
                    }
                } label: {
                    Text(vm.isConnected ? "断开" : "连接")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 72, height: 48)
                        .background(vm.isConnected ? Color.red.opacity(0.7) : Color.cyan,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(vm.isConnected ? .white : .black)
                }
            }

            statusRow

            // ★ 自动发现的盒子（第 18 轮新增）
            //
            // 盒子端本来就在每秒广播自己的 IP，我们直接监听。
            // 这样盒子 IP 变了（DHCP 经常变）也不用手动改 —— 一次配置都不用动。
            if !vm.discoveredDevices.isEmpty {
                VStack(spacing: 6) {
                    ForEach(vm.discoveredDevices) { device in
                        Button {
                            vm.selectDevice(device)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 13))
                                Text("\(device.name) · \(device.ip)")
                                    .font(.system(size: 13, design: .monospaced))
                                Spacer()
                                if vm.boxIP == device.ip {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                vm.boxIP == device.ip
                                    ? Color.green.opacity(0.18)
                                    : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vm.isNetworkReady ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            // 用 ViewModel 镜像出来的状态（@Published），不用 vm.network.state
            // —— network 是 let 常量，它变了不会通知 SwiftUI 刷新
            Text(vm.networkStatusText)
                .font(.system(size: 13))
                .foregroundStyle(.gray)
            if !vm.deviceName.isEmpty {
                Text("· 设备：\(vm.deviceName)")
                    .font(.system(size: 13))
                    .foregroundStyle(.gray)
            }
            Spacer()
            if vm.isConnected {
                Text("已发 \(vm.sentFrames) 帧")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.gray)
            }
        }
    }

    // ══════════════════════════════════════════════════════════════

    private var metricsSection: some View {
        VStack(spacing: 12) {
            // ★ 延迟 —— 最关键的指标
            bigMetric(
                title: "端到端延迟",
                value: String(format: "%.0f", vm.totalLatencyMs),
                unit: "ms",
                caption: "采集 \(String(format: "%.0f", vm.latencyBreakdown.capture)) + 网络 \(String(format: "%.1f", vm.latencyBreakdown.network)) + 盒缓冲 \(String(format: "%.0f", vm.latencyBreakdown.box)) + 输出 \(String(format: "%.0f", vm.latencyBreakdown.output))",
                tint: vm.totalLatencyMs < 80 ? .green : (vm.totalLatencyMs < 130 ? .yellow : .orange)
            )

            HStack(spacing: 12) {
                // AEC 效果
                //
                // 判据说明（2026-10-08 修正）：
                // 0 dB 且标注「未工作」= 滤波器一次都没跑（errPower 恒 0）。
                // 但这个 0 与「盒子里有没有声音」**不是同一件事** ——
                // ERLE 用量化前的 Float 算，电视收到的是Int16 量化后的值。
                // 所以判断电视有没有声音，要看下面「发送电平」那一项。
                smallMetric(
                    title: "AEC 抑制量",
                    value: String(format: "%.1f", vm.erle),
                    unit: "dB",
                    caption: vm.erle > 10 ? "有效" : (vm.erle > 0 ? "偏弱" : "未工作"),
                    tint: vm.erle > 10 ? .green : .orange
                )

                // 啸叫
                smallMetric(
                    title: "啸叫检测",
                    value: vm.howlingDetected ? "\(vm.howlingFreqs.count)" : "0",
                    unit: vm.howlingDetected ? "处" : "",
                    caption: vm.howlingDetected
                        ? vm.howlingFreqs.prefix(2)
                            .map { String(format: "%.0f", $0) }
                            .joined(separator: "/") + " Hz"
                        : "未检出",
                    tint: vm.howlingDetected ? .red : .green
                )

                // 电平
                //
                // ★ 2026-10-08 修正：caption 不能只看 isSinging。
                //   isSinging 是 AEC 双讲检测的结果，而双讲检测在
                //   errPower 恒为 0 时会永远返回 false → 于是
                //   **电平明明在跳动，caption 却一直显示「静音」**
                //   （2026-10-08 实机验证时踩到，极易误导排查方向）。
                //
                //   正确判据：直接看电平本身。
                //   有信号却判定为静音 → 才是真的异常。
                smallMetric(
                    title: "输入电平",
                    value: vm.currentLevelDb <= -100 ? "—" : String(format: "%.0f", vm.currentLevelDb),
                    unit: "dB",
                    caption: vm.currentLevelDb > -90 ? (vm.isSinging ? "检测到人声" : "有信号") : "静音",
                    tint: vm.currentLevelDb > -50 ? .green : .gray
                )

                // ★ 新增（第十三轮）：量化后的实际发送电平
                //
                // 作用：一眼区分「麦克风没采到声音」和「采到了但链路断了」。
                //
                //   输入电平 = AEC 之前的 Float 幅度（麦克风采集到的）
                //   发送电平 = Int16 量化**之后**真正进包的幅度
                //
                // 曾用它排查过「电视没声音」，结论是**盒子端缺播放器线程**，
                // 与量化无关。但这个指标本身很有用，保留下来。
                smallMetric(
                    title: "发送电平",
                    value: vm.sentLevelDb <= -100 ? "—" : String(format: "%.0f", vm.sentLevelDb),
                    unit: "dB",
                    caption: vm.sentLevelDb > -60 ? "有数据" : "全零",
                    tint: vm.sentLevelDb > -60 ? .green : .red
                )
            }
        }
    }

    private var waveformSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("电平波形（最近 60 帧· 每帧 5ms）")
                .font(.system(size: 12))
                .foregroundStyle(.gray)
            WaveformView(values: vm.levelHistory)
                .frame(height: 70)
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    // ══════════════════════════════════════════════════════════════
    //  DSP 参数开关 —— 用来现场找最优值
    // ══════════════════════════════════════════════════════════════

    private var controlsSection: some View {
        VStack(spacing: 10) {
            Text("DSP 参数（现场调）")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            toggleRow("回声消除 AEC", value: vm.aecOn)
                { vm.aecOn = $0 }
            sliderRow("AEC 强度", value: vm.aecStrength, range: 0...1, fmt: "%.2f") {
                vm.aecStrength = $0
            }
            toggleRow("啸叫抑制", value: vm.howlOn)
                { vm.howlOn = $0 }
            sliderRow("啸叫强度", value: vm.howlStrength, range: 0...1, fmt: "%.2f") {
                vm.howlStrength = $0
            }
            sliderRow("输入增益", value: vm.inputGain, range: -20...20, fmt: "%.0f dB") {
                vm.inputGain = $0
            }
            sliderRow("混响", value: vm.reverb, range: 0...0.4, fmt: "%.2f") {
                vm.reverb = $0
            }
            Picker("混响预设", selection: $vm.reverbPreset) {
                ForEach(ReverbPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func toggleRow(_ title: String, value: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: Binding(get: { value }, set: onChange))
                .labelsHidden()
                .tint(.cyan)
        }
    }

    private func sliderRow(_ title: String, value: Double, range: ClosedRange<Double>,
                          fmt: String, onChange: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(.white)
                Spacer()
                Text(String(format: fmt, value))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.cyan)
            }
            Slider(value: Binding(get: { value }, set: onChange), in: range)
                .tint(.cyan)
        }
    }

    private var disconnectedHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 36))
                .foregroundStyle(.gray)
            Text("请在下面输入盒子 IP，点「连接」")
                .font(.system(size: 13))
                .foregroundStyle(.gray)
            // ★ 2026-10-09 修复：原来这里写死了 "盒子 IP：192.168.1.5"，
            //   用户改了输入框但这行提示不变，造成误导
            //   （用户反馈「文本框改成.10 但提示还是 .5」）。
            //   现在显示 vm.boxIP 的当前值，与输入框保持一致。
            Text("盒子 IP：\(vm.boxIP)")
                .font(.system(size: 12, design: .monospaced))
                // boxIPIsValid 是 ContentView 自己的计算属性，不是 vm 的成员
                .foregroundStyle(boxIPIsValid ? Color.cyan.opacity(0.8) : Color.orange)
        }
        .padding(.top, 30)
    }

    // ══════════════════════════════════════════════════════════════

    private func bigMetric(title: String, value: String, unit: String,
                           caption: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(.gray)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 46, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                Text(unit).font(.system(size: 16)).foregroundStyle(tint.opacity(0.7))
            }
            Text(caption)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func smallMetric(title: String, value: String, unit: String,
                             caption: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.gray)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
                Text(unit).font(.system(size: 11)).foregroundStyle(tint.opacity(0.7))
            }
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.gray)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

// ══════════════════════════════════════════════════════════════════════
//  波形图
// ══════════════════════════════════════════════════════════════════════

struct WaveformView: View {
    let values: [Float]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / CGFloat(max(values.count, 1))
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    let norm = (max(-60, min(0, v)) + 60) / 60
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color(for: v))
                        .frame(width: max(w - 1, 1),
                               height: max(CGFloat(norm) * geo.size.height, 1))
                }
            }
        }
    }

    private func color(for v: Float) -> Color {
        if v > -3 { return .red }
        if v > -12 { return .orange }
        return .green
    }
}

// ══════════════════════════════════════════════════════════════════════

#Preview {
    ContentView()
}
