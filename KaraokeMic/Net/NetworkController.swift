//
//  NetworkController.swift
//  雪宝 K歌麦克风 · iOS 端
//
//  负责：设备发现、连接管理、音频发送、PING/PONG 延迟测量。
//  使用 Network.framework（NWConnection），原生、低延迟、支持 UDP。
//
//  ⚠️ 本地网络权限（iOS 14+）：
//     Info.plist 必须有 NSLocalNetworkUsageDescription，
//     否则所有 NWConnection 到局域网都会静默失败。这是必踩的坑。
//

import Foundation
import Network
import UIKit

/// 设备发现结果。
struct DiscoveredDevice: Identifiable, Equatable {
    let id: String         // "ip:port" 作为唯一标识
    var name: String
    var ip: String
    var port: UInt16
    var controlPort: UInt16
    var appVersion: String
    var lastSeen: Date
    var rttMs: Float?      // 延迟（如果已测）
}

/// 连接状态。
enum ConnectionState: Equatable {
    case idle
    case discovering
    case connecting
    case handshaking
    case ready
    case failed(String)

    var displayText: String {
        switch self {
        case .idle:           return "未连接"
        case .discovering:    return "搜索盒子中…"
        case .connecting:     return "连接中…"
        case .handshaking:    return "协商参数…"
        case .ready:          return "已连接"
        case .failed(let msg): return "失败：\(msg)"
        }
    }

    var isConnected: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// 网络控制器 —— 主线程操作，内部用 GCD 切到后台队列。
final class NetworkController: NSObject, ObservableObject {

    // MARK: - 公共状态（UI 观察这些）

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var roundTripMs: Float = 0
    @Published private(set) var packetsSent: Int = 0
    @Published private(set) var packetsLost: Int = 0

    /// 盒子端上报的统计
    @Published var bufferFillMs: Float = 0
    @Published var underruns: Int = 0
    @Published var boxAudioLevelDb: Float = -120
    @Published var boxOutputVolume: Float = 1.0
    @Published var boxSystemVolume: Int = 0

    // MARK: - 私有状态

    private var audioConnection: NWConnection?
    private var controlConnection: NWConnection?
    private var discoveryListener: NWListener?
    private let networkQueue = DispatchQueue(label: "com.xuebao.karamic.net", qos: .userInitiated)

    private var sequence: UInt32 = 0
    private var nextExpectedSeq: UInt32 = 0
    private var pingTimer: Timer?
    private var pingSentAt: [UInt64] = []      // 时间戳队列，用于算 RTT
    private var lastAudioReceivedAt: Date = Date()

    private var currentDevice: DiscoveredDevice?
    private var pendingHelloAck = false

    /// 音频发送统计（本端）
    private var sentSeqSet: Set<UInt32> = []

    // MARK: - 设备发现

    /// 本机 IPv4 地址（用于确定扫描哪个网段）
    private var localIP: String = ""

    /// 是否仍在扫描（控制 15 秒一轮的重扫）
    private var scanning = false

    // ══════════════════════════════════════════════════════════════════
    //  ★★ 网段单播扫描（2026-10-09 从验证版同步 —— 自动发现的真正主力）
    // ══════════════════════════════════════════════════════════════════
    //
    //  【原来的做法为什么不行】
    //  原实现是「发广播查询 + NWListener 监听广播回复」。
    //  但 iOS 14+ **接收 UDP 广播/组播必须持有
    //  com.apple.developer.networking.multicast 这个 entitlement**，
    //  而它只对付费开发者账号开放 —— 用户是用爱思助手 + 个人证书装的，
    //  签名里根本带不了。结果就是监听循环一直在跑，但**一个包都收不到**，
    //  用户看到的永远是「IP 文本框里还是旧的 192.168.1.5」。
    //
    //  【单播不需要任何特殊权限】
    //  向 192.168.1.1 ~ 192.168.1.254 的 50002 端口逐个发一个查询包，
    //  盒子收到后**单播回复**。254 个小包不到 1 秒发完，
    //  换来的是 100% 可靠的发现：
    //    · 不依赖广播权限（个人签名可用）
    //    · 不受路由器「AP 隔离 / 禁止广播」影响
    //    · 手机先开、盒子后开也能扫到（每 15 秒重扫一轮）
    //
    //  盒子端对应实现：ReceiverService.startDiscoveryResponder()
    //  —— 50002 从「只广播不收」改成「也监听并单播回复」。
    // ══════════════════════════════════════════════════════════════════

    /// 开始扫描局域网内的盒子。
    func startDiscovery() {
        state = .discovering
        discoveredDevices.removeAll()
        scanning = true

        resolveLocalIP()
        scanSubnet()
    }

    /// 停止扫描。
    func stopDiscovery() {
        scanning = false
        discoveryListener?.cancel()
        discoveryListener = nil
        if case .discovering = state { state = .idle }
    }

    /// 扫描同网段的所有 IP，收集回复。
    ///
    /// 用 BSD socket 而不是 Network.framework —— 后者每个目标要建一条
    /// NWConnection，254 条连接太重；UDP 单播用 BSD socket 发是标准做法。
    func scanSubnet() {
        let parts = localIP.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else {
            NSLog("[Discovery] 本机 IP 未知(\(localIP))，跳过扫描")
            return
        }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
        NSLog("[Discovery] 开始扫描 \(prefix).1~254 的 \(KaraokeProtocol.discoveryPort) 端口…")

        // ── 建一个 UDP socket（系统自动分配源端口用于收回复）──
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            NSLog("[Discovery] socket 创建失败 errno=\(errno)")
            return
        }
        defer { close(fd) }

        // 接收超时 300ms —— 用于「收回复」阶段的循环，避免卡死
        var tv = timeval()
        tv.tv_sec = 0
        tv.tv_usec = 300_000
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let payload = ControlFrameBuilder.build(
            ControlMessage(
                cmd: "discover_query",
                data: ["clientName": .string(UIDevice.current.name)]
            ),
            type: .discoverQuery
        )

        // ── ① 发查询：向每个 IP 的 50002 发一个包 ──
        for i in 1...254 {
            let ip = "\(prefix).\(i)"
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_port = KaraokeProtocol.discoveryPort.bigEndian   // 网络字节序
            addr.sin_addr.s_addr = inet_addr(ip)                      // 已是网络字节序

            let sent = payload.withUnsafeBytes { raw -> Int in
                var a = addr                                          // 需要可变副本
                return withUnsafePointer(to: &a) { ptr -> Int in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, raw.baseAddress, raw.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0 && i == 1 {
                NSLog("[Discovery] sendto 失败 errno=\(errno)")
            }
        }

        // ── ② 收回复：最多等 2 秒 ──
        let deadline = Date().addingTimeInterval(2.0)
        var buf = [UInt8](repeating: 0, count: 4096)
        var found = 0

        while Date() < deadline {
            let n = recvfrom(fd, &buf, buf.count, 0, nil, nil)
            if n > 0 {
                let data = Data(buf[0..<n])
                if let (header, message) = ControlFrameBuilder.parse(data),
                   header.type == .discoverReply,
                   let msg = message {
                    handleDiscoveryReply(msg)
                    found += 1
                }
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                continue        // 超时，继续等
            } else {
                break
            }
        }

        NSLog("[Discovery] 扫描结束，本次收到 \(found) 个回复（累计 \(discoveredDevices.count) 个盒子）")

        // ── ③ 15 秒后再扫一轮：盒子后开的、或者换了 IP 的都能跟上 ──
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.scanning else { return }
            self.scanSubnet()
        }
    }

    /// 解析手机当前的 IPv4 地址（确定扫描网段用）
    private func resolveLocalIP() {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return }
        defer { freeifaddrs(head) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let interface = current.pointee

            // ★ ifa_addr 是可选的，必须先解包
            if let addr = interface.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(addr.pointee.sa_len != 0
                                    ? Int(addr.pointee.sa_len)
                                    : MemoryLayout<sockaddr_in>.size)
                getnameinfo(addr, len, &hostname, socklen_t(hostname.count),
                            nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                if ip.hasPrefix("192.168.") {
                    localIP = ip
                    NSLog("[Discovery] 手机 IP: \(ip)")
                    break
                }
            }
            ptr = interface.ifa_next
        }
    }

    /// 【保留但已不再作为主要手段】广播 DISCOVER_QUERY 到 255.255.255.255:50002。
    ///
    /// iOS 发出广播不需要权限（收才需要），所以这个包能出去，
    /// 但**收不到回复** —— 收回复需要 multicast entitlement。
    /// 保留它只是为了让局域网内其他类型的客户端仍能发现我们。
    private func broadcastDiscoverQuery() {
        guard let conn = try? NWConnection(
            host: NWEndpoint.Host("255.255.255.255"),
            port: NWEndpoint.Port(rawValue: KaraokeProtocol.discoveryPort)!,
            using: .udp
        ) else { return }

        conn.start(queue: networkQueue)

        var header = PacketHeader()
        header.type = .discoverQuery
        header.payloadLength = 0

        conn.send(content: header.serialize(), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// 监听 DISCOVER_REPLY。
    private func startDiscoveryListener() {
        do {
            let listener = try NWListener(
                using: .udp,
                on: NWEndpoint.Port(rawValue: KaraokeProtocol.discoveryPort)!
            )

            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: self?.networkQueue ?? DispatchQueue.global())

                conn.receiveMessage { [weak self] data, _, _, _ in
                    guard let self, let data,
                          let (header, message) = ControlFrameBuilder.parse(data),
                          header.type == .discoverReply,
                          let msg = message else { return }

                    self.handleDiscoveryReply(msg)
                }
            }

            listener.start(queue: networkQueue)
            discoveryListener = listener

            // 周期性重发广播（盒子的广播可能错过）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, case .discovering = self.state else { return }
                self.broadcastDiscoverQuery()
                self.startDiscoveryListener()
            }

        } catch {
            NSLog("[NetworkController] 发现监听失败: \(error)")
        }
    }

    private func handleDiscoveryReply(_ message: ControlMessage) {
        guard let data = message.data,
              let ip = data["ip"]?.stringValue,
              let name = data["name"]?.stringValue else { return }

        let port = UInt16(data["port"]?.floatValue ?? Float(KaraokeProtocol.audioPort))
        let ctrlPort = UInt16(data["ctrlPort"]?.floatValue ?? Float(KaraokeProtocol.controlPort))
        let version = data["appVersion"]?.stringValue ?? "?"

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let device = DiscoveredDevice(
                id: "\(ip):\(port)",
                name: name, ip: ip, port: port,
                controlPort: ctrlPort,
                appVersion: version,
                lastSeen: Date(),
                rttMs: nil
            )

            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                self.discoveredDevices[idx] = device
            } else {
                self.discoveredDevices.append(device)
            }
        }
    }

    // MARK: - 连接

    /// 连接到指定设备。
    func connect(to device: DiscoveredDevice) {
        disconnect()

        currentDevice = device
        state = .connecting

        // ── 1. 建立音频连接（单向高频） ──
        let audioPort = NWEndpoint.Port(rawValue: device.port)!
        guard let audioConn = try? NWConnection(
            host: NWEndpoint.Host(device.ip),
            port: audioPort,
            using: .udp
        ) else {
            state = .failed("无法创建音频连接")
            return
        }

        audioConnection = audioConn
        audioConn.stateUpdateHandler = { [weak self] connState in
            switch connState {
            case .ready:
                self?.handleAudioConnectionReady()
            case .failed(let error):
                DispatchQueue.main.async {
                    self?.state = .failed(error.localizedDescription)
                }
            default:
                break
            }
        }
        audioConn.start(queue: networkQueue)

        // ── 2. 建立控制连接（双向） ──
        let ctrlPort = NWEndpoint.Port(rawValue: device.controlPort)!
        guard let ctrlConn = try? NWConnection(
            host: NWEndpoint.Host(device.ip),
            port: ctrlPort,
            using: .udp
        ) else {
            state = .failed("无法创建控制连接")
            return
        }

        controlConnection = ctrlConn
        pendingHelloAck = true

        ctrlConn.stateUpdateHandler = { [weak self] connState in
            switch connState {
            case .ready:
                self?.sendHello()
                // 启动控制面接收循环
                self?.receiveControlLoop(on: ctrlConn)
            case .failed(let error):
                DispatchQueue.main.async {
                    self?.state = .failed(error.localizedDescription)
                }
            default:
                break
            }
        }
        ctrlConn.start(queue: networkQueue)
    }

    private func handleAudioConnectionReady() {
        DispatchQueue.main.async { [weak self] in
            self?.state = .handshaking
        }
        sendHello()
    }

    private func sendHello() {
        let msg = ControlMessage(cmd: ControlMessage.ControlCmd.hello, id: 1, data: [
            "appVersion": .string("1.0.0"),
            "codec": .string("pcm_s16le"),
            "sampleRate": .number(48000),
            "channels": .number(1),
            "frameMs": .number(20)
        ])
        sendControl(msg)
    }

    /// 控制面接收循环（递归）。
    private func receiveControlLoop(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data {
                self.handleControlPacket(data)
            }

            if !isComplete, error == nil {
                self.receiveControlLoop(on: conn)
            }
        }
    }

    private func handleControlPacket(_ data: Data) {
        guard let (header, message) = ControlFrameBuilder.parse(data) else { return }

        DispatchQueue.main.async {
            switch header.type {
            case .pong:
                self.handlePong(data)
            case .stats:
                self.handleStats(message)
            case .control:
                self.handleControlMessage(message)
            default:
                break
            }
        }
    }

    private func handleControlMessage(_ message: ControlMessage?) {
        guard let msg = message else { return }

        switch msg.cmd {
        case ControlMessage.ControlCmd.helloAck:
            // 协商完成 → 开始发音频
            let bufferMs = msg.data?["bufferMs"]?.floatValue ?? 40
            DispatchQueue.main.async {
                self.bufferFillMs = bufferMs
            }
            sendControl(ControlMessage(cmd: ControlMessage.ControlCmd.startAudio, id: 2))

        case ControlMessage.ControlCmd.ready:
            // 盒子已预填充缓冲，可以正式开始
            DispatchQueue.main.async {
                self.state = .ready
                self.startPingTimer()
            }
            // 重置序列号统计
            sentSeqSet.removeAll()
            nextExpectedSeq = 0

        case ControlMessage.ControlCmd.error:
            let err = msg.data?["error"]?.stringValue ?? "unknown"
            DispatchQueue.main.async {
                self.state = .failed(err)
            }

        default:
            break
        }
    }

    private func handleStats(_ message: ControlMessage?) {
        guard let msg = message, let d = msg.data else { return }

        bufferFillMs = d["bufferFillMs"]?.floatValue ?? bufferFillMs
        underruns = Int(d["underruns"]?.floatValue ?? 0)
        boxAudioLevelDb = d["audioLevelDb"]?.floatValue ?? boxAudioLevelDb
        boxOutputVolume = d["outputVolume"]?.floatValue ?? boxOutputVolume
        boxSystemVolume = Int(d["systemVolume"]?.floatValue ?? 0)
    }

    // MARK: - 发送音频（实时音频线程调用）

    /// 发送一帧音频。
    /// ⚠️ 这个方法会在实时音频线程被调用，
    ///    所以不能做重活（不能加锁等待、不能 print、不能 JSON 编码）。
    ///    NWConnection.send 是非阻塞的，符合要求。
    func sendAudioFrame(samples: [Float], sampleRate: UInt32 = 48000) {
        guard let conn = audioConnection, state == .ready else { return }

        let packet = AudioFrameBuilder.build(
            from: samples, seq: sequence, sampleRate: sampleRate
        )

        conn.send(content: packet, completion: .contentProcessed { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error == nil {
                    self.packetsSent += 1
                }
            }
        })

        sequence &+= 1
    }

    // MARK: - PING / PONG 延迟测量

    private func startPingTimer() {
        pingTimer?.invalidate()
        // 每 500ms 一次。取最近 5 次的中位数。
        pingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
        if let pingTimer {
            RunLoop.main.add(pingTimer, forMode: .common)
        }
    }

    private func sendPing() {
        // 记录发送时间（单调时钟，不受系统时间调整影响）
        let t0 = DispatchTime.now().uptimeNanoseconds
        pingSentAt.append(t0)
        if pingSentAt.count > 10 { pingSentAt.removeFirst() }

        let msg = ControlMessage(cmd: "ping", data: [
            "t0": .number(Double(t0 & 0xFFFFFFFF))
        ])
        sendControl(msg)
    }

    private func handlePong(_ data: Data) {
        guard let (header, message) = ControlFrameBuilder.parse(data) else { return }
        let t0Double = message?.data?["t0"]?.floatValue ?? 0
        let t0 = UInt64(t0Double)
        let t1 = DispatchTime.now().uptimeNanoseconds

        if t1 >= t0 {
            let rttNs = t1 - t0
            let rttMs = Float(rttNs) / 1_000_000.0

            // 用最近 5 次的中位数（抗抖动）
            roundTripMs = roundTripMs == 0 ? rttMs : (roundTripMs * 0.7 + rttMs * 0.3)
        }
    }

    // MARK: - 控制发送

    private func sendControl(_ message: ControlMessage) {
        guard let conn = controlConnection else { return }
        let data = ControlFrameBuilder.build(message)
        conn.send(content: data, completion: .contentProcessed { error in
            if let error {
                NSLog("[NetworkController] 控制发送失败: \(error)")
            }
        })
    }

    /// 设置盒子端音量（0~1）。只影响我们的音频轨，不影响盒子其他 App。
    func setBoxVolume(_ volume: Float) {
        sendControl(ControlMessage(cmd: ControlMessage.ControlCmd.setVolume, data: [
            "volume": .number(volume)
        ]))
    }

    /// 通知盒子静音/取消静音。
    func setBoxMuted(_ muted: Bool) {
        sendControl(ControlMessage(cmd: "set_mute", data: [
            "muted": .bool(muted)
        ]))
    }

    // MARK: - 断线检测

    /// 检查连接是否还活着。由 App 层定时调用。
    func checkConnectionHealth() {
        guard state == .ready else { return }

        // 超过 2 秒没有收到任何包的响应 → 判定断线
        if Date().timeIntervalSince(lastAudioReceivedAt) > 2.0 {
            DispatchQueue.main.async {
                self.state = .failed("连接超时")
            }
        }
    }

    // MARK: - 断开

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil

        sendControl(ControlMessage(cmd: ControlMessage.ControlCmd.bye))

        audioConnection?.cancel()
        controlConnection?.cancel()
        discoveryListener?.cancel()

        audioConnection = nil
        controlConnection = nil
        discoveryListener = nil
        currentDevice = nil
        sequence = 0
        state = .idle
        roundTripMs = 0
    }

    // MARK: - 手动连接（兜底）

    /// 手动输入 IP 连接。
    func connectManually(ip: String, port: UInt16 = KaraokeProtocol.audioPort) {
        let device = DiscoveredDevice(
            id: "\(ip):\(port)",
            name: "手动连接 \(ip)",
            ip: ip, port: port,
            controlPort: KaraokeProtocol.controlPort,
            appVersion: "?",
            lastSeen: Date(),
            rttMs: nil
        )
        connect(to: device)
    }

    /// IP 段扫描兜底。
    func scanIPRange(basePrefix: String = "192.168.1") {
        networkQueue.async { [weak self] in
            guard let self else { return }

            for host in 1...254 {
                let ip = "\(basePrefix).\(host)"
                let port = NWEndpoint.Port(rawValue: KaraokeProtocol.audioPort)!

                guard let probe = try? NWConnection(
                    host: NWEndpoint.Host(ip), port: port, using: .udp
                ) else { continue }

                probe.start(queue: self.networkQueue)
                probe.stateUpdateHandler = { connState in
                    if case .ready = connState {
                        // 端口有响应 → 尝试当盒子
                        DispatchQueue.main.async {
                            let device = DiscoveredDevice(
                                id: "\(ip):\(KaraokeProtocol.audioPort)",
                                name: "扫描到 \(ip)",
                                ip: ip,
                                port: KaraokeProtocol.audioPort,
                                controlPort: KaraokeProtocol.controlPort,
                                appVersion: "?",
                                lastSeen: Date(),
                                rttMs: nil
                            )
                            if !self.discoveredDevices.contains(where: { $0.id == device.id }) {
                                self.discoveredDevices.append(device)
                            }
                        }
                    }
                    probe.cancel()
                }
            }
        }
    }
}
