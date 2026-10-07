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
    }

    // MARK: - 连接

    func connect(boxIP: String) {
        // IP 变了要重建 NetworkController
        if network.hostValue != boxIP {
            // NetworkController 的 host 是 let，简化处理：断开后由用户重连
            // （真要热切换，把 host 改成 var 或重建实例）
        }

        network.connect()

        // 等连接就绪后启动音频
        let nc = network
        var started = false
        let check = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
            .prefix(20)                                    // 最多等 4 秒
            .sink { [weak self] _ in
                guard let self else { return }
                if nc.state == .ready && !started {
                    started = true
                    self.startAudio()
                }
            }
        cancellables.insert(check)
    }

    func disconnect() {
        audio.stop()
        network.disconnect()
        isConnected = false
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
