//
//  AppViewModel.swift
//  雪宝 K歌麦克风 · iOS 端
//
//  应用的中央状态管理。UI 与网络/音频引擎之间的桥梁。
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {

    // MARK: - 子系统

    let network = NetworkController()
    private(set) var audio: AudioEngineController!

    // MARK: - 状态

    @Published var isRecording = false
    @Published var params = SignalParameters.default
    @Published var activeMode: PerformMode = .standard
    @Published var monitoringEnabled = false
    @Published var boxVolume: Float = 0.75
    @Published var accompanimentVolume: Float = 0.6
    @Published var latencyCompensationMs: Float = 0
    @Published var errorMessage: String?

    // MARK: - 生命周期

    private var cancellables: Set<AnyCancellable> = []
    private var heartbeatTimer: Timer?

    init() {
        audio = AudioEngineController(network: network)

        // 参数变更 → 同步到音频引擎
        $params
            .dropFirst()
            .sink { [weak self] newParams in
                self?.audio.updateParameters(newParams)
            }
            .store(in: &cancellables)

        // 盒子音量变更 → 实时下发
        $boxVolume
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] vol in
                guard self?.network.state == .ready else { return }
                self?.network.setBoxVolume(vol)
            }
            .store(in: &cancellables)

        // 连接状态变化 → 处理录音自动启停
        network.$state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.handleConnectionChange(state)
            }
            .store(in: &cancellables)

        startHeartbeat()
    }

    // MARK: - 派生状态

    /// 当前连接的设备。
    var connectedDevice: DiscoveredDevice? {
        guard network.state == .ready else { return nil }
        return network.discoveredDevices.first { $0.ip == lastConnectedIP }
    }

    private var lastConnectedIP: String = ""

    /// 端到端延迟估算（ms）。
    var latencyMs: Float {
        (network.roundTripMs / 2) + network.bufferFillMs + 20 - latencyCompensationMs
    }

    /// 连接状态颜色。
    var connectionColor: Color {
        switch network.state {
        case .ready:    return KaraokeTheme.success
        case .connecting, .handshaking, .discovering: return KaraokeTheme.warning
        case .failed:   return KaraokeTheme.danger
        case .idle:     return .gray
        }
    }

    // MARK: - 连接

    func connect(to device: DiscoveredDevice) {
        lastConnectedIP = device.ip
        network.connect(to: device)
    }

    func disconnect() {
        stopRecording()
        network.disconnect()
    }

    private func handleConnectionChange(_ state: ConnectionState) {
        switch state {
        case .ready:
            errorMessage = nil
            // 自动开始收音 —— 用户连上就是想唱
            if !isRecording { startRecording() }
        case .failed(let msg):
            errorMessage = msg
            if isRecording { stopRecording() }
        case .idle:
            if isRecording { stopRecording() }
        default:
            break
        }
    }

    // MARK: - 录音控制

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        do {
            try audio.start()
            isRecording = true
        } catch {
            errorMessage = "启动失败：\(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        audio.stop()
        isRecording = false
    }

    // MARK: - 盒子控制

    func setBoxMuted(_ muted: Bool) {
        network.setBoxMuted(muted)
        boxVolume = muted ? 0 : 0.75
    }

    // MARK: - 模式切换

    func applyPerformMode(_ mode: PerformMode) {
        activeMode = mode
        // 动画过渡：分步设置各个参数，避免瞬间跳变
        withAnimation(.easeInOut(duration: 0.35)) {
            params = mode.parameters
        }
    }

    // MARK: - 心跳

    /// 定期检查连接健康（配合 UI 刷新）。
    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.network.checkConnectionHealth()
            }
        }
    }
}
