//
//  NetworkController.swift
//  雪宝 K歌麦克风 · 极简验证版
//
//  UDP 音频发送 + 控制通道 + 往返延迟测量。
//
//  极简策略（与正式版的最大差异）：
//  · **不做** mDNS/Bonjour 自动发现 —— 验证阶段手填 IP 更确定、问题更好定位
//  · **不做** 断线自动重连 —— 手动重连，行为可预测
//  ·保留：音频发送（50000）、控制（50001）、PING/PONG 延迟测量
//
//  为什么保留 PING/PONG：
//  PONG 必须**原样回填** PING 的 payload，这样iPhone 只需 (t2-t0) 就能算 RTT，
//  不需要两端时钟同步。延迟实测就靠它。
//

import Foundation
import Network
import UIKit

final class NetworkController {

    enum State: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)

        var text: String {
            switch self {
            case .idle:return "未连接"
            case .connecting:  return "连接中…"
            case .ready:return "已连接"
            case .failed(let e): return "失败：\(e)"
            }
        }
    }

    // MARK: - 状态

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// 往返延迟（ms）
    private(set) var roundTripMs: Float = 0
    /// 盒子侧缓冲深度（ms）
    private(set) var bufferFillMs: Float = 0
    /// 端到端延迟估算（ms）
    var estimatedLatencyMs: Float { (roundTripMs / 2) + bufferFillMs + 20 }

    private(set) var deviceName: String = ""

    var onStateChange: ((State) -> Void)?
    var onRttUpdate: ((Float) -> Void)?

    // MARK: - 内部

    /// 当前连接的盒子 IP（UI 用来判断是否需要重建连接）
    private(set) var hostValue: String

    private let audioPort: UInt16
    private let controlPort: UInt16

    private var audioConnection: NWConnection?
    private var controlConnection: NWConnection?
    private var pingTimer: Timer?

    private var seq: UInt32 = 0
    private let pingSeqBase: UInt32 = 0x7000_0000     // 与音频 seq 区间隔离

    /// 真实测量到的往返延迟（纳秒），PONG 回来时计算
    private var pingSentAt: [UInt32: Date] = [:]

    // MARK: - 初始化

    init(host: String, audioPort: UInt16 = KaraokeProtocol.audioPort,
         controlPort: UInt16 = KaraokeProtocol.controlPort) {
        self.hostValue = host
        self.audioPort = audioPort
        self.controlPort = controlPort
    }

    deinit { disconnect() }

    // MARK: - 连接

    func connect() {
        disconnect()

        guard let audioPortNW = NWEndpoint.Port(rawValue: audioPort),
              let controlPortNW = NWEndpoint.Port(rawValue: controlPort),
              IPv4Address(hostValue) != nil
        else {
            // IPv4Address 初始化失败 → IP 格式不对
            state = .failed("IP 格式不正确：\(hostValue)")
            return
        }

        state = .connecting
        hasAck = false

        // ── 音频连接（单向上行）──
        //
        // ⚠️ UDP 的 `.ready` **不代表对端存在**，只代表本地 socket 绑定成功。
        //    所以这里绝不能直接 `state = .ready`（那是之前的 bug）。
        let audio = NWConnection(host: NWEndpoint.Host(hostValue),
                                 port: audioPortNW, using: .udp)
        audioConnection = audio
        audio.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                // socket 就绪 → 发 hello 探活，但**状态仍保持 .connecting**
                self.sendHello()
                self.startPing()
                self.startAckTimeout()
            case .failed(let err):
                self.state = .failed("\(err.localizedDescription)")
            default:
                break
            }
        }
        audio.start(queue: .global(qos: .userInteractive))

        // ── 控制连接（双向）──
        let control = NWConnection(host: NWEndpoint.Host(hostValue),
                                   port: controlPortNW, using: .udp)
        controlConnection = control
        control.stateUpdateHandler = { [weak self] s in
            if case .failed(let err) = s {
                self?.state = .failed("\(err.localizedDescription)")
            }
        }
        control.start(queue: .global(qos: .utility))

        // 控制连接收包
        receiveControlLoop()
    }

    /// 控制通道收包循环。
    ///
    /// NWConnection.receiveMessage 是「一次性」的 —— 每调一次只收一个包，
    /// 所以必须收到后再次调用自己，否则只能收到第一条控制消息。
    /// 用 controlConnection 做身份校验，disconnect() 置空后循环自然停止。
    private func receiveControlLoop() {
        guard let connection = controlConnection else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            // 身份校验：期间可能已经 disconnect/重连，避免往老连接上挂循环
            guard self.controlConnection === connection else { return }
            if let data {
                self.handleControl(data)
            }
            self.receiveControlLoop()
        }
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        audioConnection?.cancel()
        controlConnection?.cancel()
        audioConnection = nil
        controlConnection = nil
        pingSentAt.removeAll()
        state = .idle
    }

    // MARK: - 握手超时检测

    /// 发了 hello 之后等一会儿，看盒子有没有回 hello_ack。
    ///
    /// ★ UDP 没有「连接失败」这种事件 ——
    ///   发出去的包如果对端不存在，会被内核静默丢弃，
    ///   既不报错也不超时。所以必须自己做超时判断，
    ///   否则 UI 会一直显示「已连接」，用户以为连上了，其实一个包都没送到。
    private func startAckTimeout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + ackTimeout) { [weak self] in
            guard let self, self.state == .connecting, !self.hasAck else { return }
            self.state = .failed("盒子无响应（\(self.hostValue)）\n请检查：IP 是否正确 / 是否同一 WiFi / 盒子服务是否已启动")
        }
    }

    // MARK: - 发送

    /// 发送一帧音频（实时线程调用，必须轻量）
    func sendAudioFrame(samples: [Float], sampleRate: UInt16 = 48000) {
        guard state == .ready, let conn = audioConnection else { return }

        let packet = AudioFrameBuilder.build(from: samples, seq: seq, sampleRate: sampleRate)
        seq &+= 1
        conn.send(content: packet, completion: .contentProcessed { _ in })
    }

    /// 发送 hello 握手
    private func sendHello() {
        let msg = ControlMessage.build(cmd: "hello",
                                      data: ["clientName": UIDevice.current.name,
                                             "appVersion": "verify-1.0"])
        sendControl(msg)
    }

    /// 主动通知盒子「我要断开」。
    ///
    /// ★ 为什么必须发（2026-10-09 用户实测现象）：
    ///   手机断开后盒子仍显示「手机已连接」。原因是 UDP 没有断开事件，
    ///   不发 bye 的话盒子只能靠「3 秒没收到音频包」的空闲超时才反应过来。
    ///   发了 bye，盒子立刻复位，界面状态也就同步了。
    func sendBye() {
        let msg = ControlMessage.build(cmd: "bye",
                                       data: ["clientName": UIDevice.current.name])
        sendControl(msg)
    }

    func sendControl(_ data: Data) {
        guard let conn = controlConnection else { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - PING / 延迟测量

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
        sendPing()      // 立刻打一次
    }

    private func sendPing() {
        guard state == .ready, let conn = controlConnection else { return }

        let p = pingSeqBase &+ (roundTripMs == 0 ? 0 : seq & 0xFFFF)
        let sentAt = Date()
        pingSentAt[p] = sentAt

        // payload 直接用时间戳，PONG 会原样带回
        var payload = Data()
        let ms = UInt64(sentAt.timeIntervalSince1970 * 1000)
        payload.appendUInt32BE(UInt32(ms >> 32))
        payload.appendUInt32BE(UInt32(ms & 0xFFFFFFFF))

        var header = PacketHeader()
        header.type = .ping
        header.seq = p
        header.payloadLength = UInt32(payload.count)

        var packet = header.serialize()
        packet.append(payload)
        conn.send(content: packet, completion: .contentProcessed { _ in })
    }

    // MARK: - 控制包处理

    private func handleControl(_ data: Data) {
        guard let header = PacketHeader.parse(data), header.type == .pong
                || header.type == .control else { return }

        if header.type == .pong {
            // RTT = now - pingSentAt
            guard let sentAt = pingSentAt.removeValue(forKey: header.seq) else { return }
            let rtt = Float(Date().timeIntervalSince(sentAt) * 1000)
            roundTripMs = roundTripMs == 0 ? rtt : roundTripMs * 0.7 + rtt * 0.3
            onRttUpdate?(roundTripMs)
            return
        }

        // control → 解析 JSON
        let payload = data.dropFirst(KaraokeProtocol.headerSize)
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload))
                as? [String: Any] else { return }

        let cmd = json["cmd"] as? String ?? ""
        if cmd == "hello_ack" {
            let d = json["data"] as? [String: Any]
            deviceName = d?["deviceName"] as? String ?? "盒子"
            bufferFillMs = Float(d?["bufferMs"] as? Int ?? 0)

            // ★★★ 关键修复（2026-10-09）：只有收到 hello_ack 才算真正连上
            //
            // 问题：UDP 的 NWConnection 在 `.ready` 时**只代表本地 socket 绑定成功**，
            //       它根本不检查对端是否存在。
            //       所以原来在 `.ready` 里直接 `state = .ready` 是错的 ——
            //       在公司连 `192.168.1.5`（那台机器根本不存在）也会显示「已连接」。
            //
            // 证据：用户在公司测，公司里不可能有那台盒子，但手机显示已连接。
            //
            // 正确逻辑：连接分三态
            //   .connecting → 已发出 hello，等回复
            //   .ready      → 收到 hello_ack，盒子确认在线
            //   .failed     → 超时未收到 → 明确报「盒子无响应」
            //
            // 注意：盒子端在收到**音频包**时才置 clientConnected，
            //       而 hello_ack 在收到 hello 控制包时就发 ——
            //       所以 hello_ack 是最早的「盒子在线」信号。
            hasAck = true
            if state == .connecting {
                state = .ready
            }
        }
    }

    /// 是否已收到盒子的 hello_ack（= 盒子真的在线）
    private var hasAck = false

    /// 等待 hello_ack 的超时时间。
    ///
    /// UDP 无连接，不存在「连接失败」事件，
    /// 只能靠「发了 hello 之后有没有人回」来判断对端在不在。
    private let ackTimeout: TimeInterval = 2.0
}
