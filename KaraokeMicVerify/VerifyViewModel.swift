//
//  VerifyViewModel.swift
//  雪宝 K歌麦克风 · 极简验证版
//
//  把网络 + 音频引擎包一层，UI 只跟它打交道。
//  参数改动统一走 `applyParameters()`，避免散落各处。
//

import SwiftUI
import Combine
import AVFoundation

final class VerifyViewModel: ObservableObject {

    // MARK: - 组件

    @Published var boxIP: String = "192.168.1.5"
    @Published private(set) var isConnected = false
    /// 网络状态镜像。`network` 是 let 常量，它内部变了不会通知 UI，
    /// 所以必须在这里复制一份成 @Published，SwiftUI 才会在 ready 时切界面。
    @Published private(set) var isNetworkReady = false
    @Published private(set) var networkStatusText: String = "未连接"
    /// 盒子名称（hello_ack 里带回来的），同样要镜像才能触发 UI 刷新
    @Published private(set) var deviceName: String = ""

    let network: NetworkController
    let audio: AudioEngineController

    // MARK: - 监测数据（从 audio 镜像到 UI）

    @Published var currentLevelDb: Float = -120
    @Published var erle: Float = 0
    @Published var howlingDetected = false
    @Published var howlingFreqs: [Float] = []
    @Published var isSinging = false
    @Published var sentFrames: Int = 0
    @Published var levelHistory: [Float] = Array(repeating: -60, count: 60)

    // MARK: - DSP 参数（UI 直接改这些）

    @Published var aecOn = true { didSet { apply() } }
    @Published var aecStrength: Double = 0.75 { didSet { apply() } }
    @Published var howlOn = true { didSet { apply() } }
    @Published var howlStrength: Double = 0.6 { didSet { apply() } }
    @Published var inputGain: Double = 0 { didSet { apply() } }
    @Published var reverb: Double = 0.12 { didSet { apply() } }
    @Published var reverbPreset: ReverbPreset = .smallRoom { didSet { apply() } }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    init() {
        let net = NetworkController(host: "192.168.1.5")
        self.network = net
        self.audio = AudioEngineController(network: net)

        // 音频引擎 → UI 的数据镜像（1 秒一次足够，省电也不拖慢音频线程）
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.syncFromAudio() }
            .store(in: &cancellables)

        // 网络状态 → UI。用NetworkController 自带的 onStateChange 回调，
        // 比轮询更准（连接成功的瞬间就能刷新界面）。
        // 注意：回调发生在 NetworkConnection 的队列上，必须切回主线程。
        net.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.applyNetworkState(state)
            }
        }
    }    // ← init() 结束

    private func applyNetworkState(_ state: NetworkController.State) {
        isNetworkReady = (state == .ready)
        networkStatusText = state.text

        // 连接就绪 → 立刻启动音频采集（只启动一次）
        if state == .ready && !isConnected {
            startAudio()
        }
    }

    // MARK: - 连接

    func connect(boxIP: String) {
        // NetworkController 的 host 是 let，改IP 需要重建实例。
        // 验证版接受这个限制：换 IP 时先断开再连。
        // （正式版会把 host 改成 var，或在这里重建 network 实例）
        network.connect()
    }

    func disconnect() {
        audio.stop()
        network.disconnect()
        isConnected = false
        isNetworkReady = false
        networkStatusText = NetworkController.State.idle.text
        sentFrames = 0
    }

    private func startAudio() {
        do {
            try AVAudioSessionPermission.ensure()
            try audio.start()
            isConnected = true
        } catch {
            network.disconnect()
            errorMessage = "麦克风启动失败：\(error.localizedDescription)"
        }
    }

    @Published var errorMessage: String? = nil

    // MARK: - 数据同步

    private func syncFromAudio() {
        currentLevelDb = audio.currentLevelDb
        erle = audio.erleDb
        howlingDetected = audio.howlingDetected
        howlingFreqs = audio.howlingFreqs
        isSinging = audio.isSinging
        sentFrames = audio.sentFrames
        levelHistory = audio.levelHistory
        if deviceName != network.deviceName {
            deviceName = network.deviceName
        }
    }

    // MARK: - 参数

    private func apply() {
        var p = audio.currentParameters
        p.aecEnabled = aecOn
        p.aecStrength = Float(aecStrength)
        p.howlingSuppressionEnabled = howlOn
        p.howlingStrength = Float(howlStrength)
        p.inputGainDb = Float(inputGain)
        p.reverbWet = Float(reverb)
        p.reverbPreset = reverbPreset
        audio.updateParameters(p)
    }
}

// ══════════════════════════════════════════════════════════════════════
//  权限
// ══════════════════════════════════════════════════════════════════════

enum AVAudioSessionPermission {
    static func ensure() throws {
        let session = AVAudioSession.sharedInstance()
        let granted = session.recordPermission

        if granted == .denied {
            throw NSError(domain: "Permission", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "麦克风权限被拒绝。请到「设置 → 雪宝 K歌麦」里打开。"
            ])
        }
        if granted == .undetermined {
            session.requestRecordPermission { _ in }
            // 第一次会弹窗，第二次点连接就已有权限
        }
    }
}
