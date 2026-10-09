//
//  DeviceDiscovery.swift
//  雪宝 K歌麦克风 · iOS 端
//
//  ════════════════════════════════════════════════════════════════
//  自动发现局域网内的盒子
//  ════════════════════════════════════════════════════════════════
//
//  【为什么需要】
//  盒子 IP 由 DHCP 分配会变（实测 192.168.1.5 → 192.168.1.10）。
//  手动改 IP 容易忘、容易打错，而且第 17 轮就因为「输入的 IP 没被使用」
//  闹了乌龙—— 用户改了半天，实际连的还是旧 IP。
//
//  【盒子端已在广播】
//  ReceiverService.startDiscoveryBroadcaster() 每秒向
//  255.255.255.255:50002 广播：
//      { cmd:"discover_reply", name:"极光盒子", ip:"192.168.1.10", ... }
//
//  【本机没有做「反向查询」】
//  ★ 重要（第 18 轮修正）：
//  最初版本我写了一个定时器，每 2 秒发 discover_query 去问盒子。
//  但**盒子端的 50002 端口只发不收**（DatagramSocket 只用于 sendto），
//  所以 discover_query 发出去没人回，自动发现实际上依赖
//  **「盒子恰好在广播」这一瞬间**。
//
//  这就带来一个缺陷：
//  若手机先启动、盒子后启动 —— 盒子开始广播后，手机的监听循环
//  仍在运行（receiveLoop 是常驻的），**能收到**；
//  但如果广播被 AP 隔离或丢失，就没有重试机会。
//
//  → 所以现在的实现：**常驻接收循环 + 定期清理**，
//    盒子只要开始广播，最多 1 秒内就会被发现。
//
//  ★ 另一个关键修正：不能用 `NWConnection.send(content:to:)`
//    —— 那个 API 需要对端已建立连接，而盒子的 50002 只广播不连接。
//    改用 BSD socket 直接 sendto 广播地址。
//
//  ★ 端口绑定：同一个端口既收广播又发查询，会自己收到自己的包。
//    所以发查询必须用**另一个本地端口**（ephemeral），
//    接收继续绑50002。
//
//════════════════════════════════════════════════════════════════

import Foundation
import Network
import UIKit

/// 发现结果
struct DiscoveredDevice: Identifiable, Equatable {
    let id: String          // IP 作为唯一标识
    let name: String        // 盒子名称
    let ip: String
    let audioPort: UInt16
    let controlPort: UInt16

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }
}

final class DeviceDiscovery: NSObject, ObservableObject {

    static let shared = DeviceDiscovery()

    /// 发现到的设备列表（UI 绑定这个）
    @Published private(set) var devices: [DiscoveredDevice] = []

    /// 手机的 IPv4 地址（用于同网段判断）
    private(set) var localIP: String = ""

    /// 接收用：绑定 50002，收盒子的广播
    private var listenSocket: NWConnection?
    /// 发送用：另一个 ephemeral 端口，用来发 discover_query
    private var sendSocket: NWConnection?

    private var isListening = false
    private let discoveryPort: UInt16 = 50002

    // MARK: - 生命周期

    func start() {
        guard !isListening else { return }
        isListening = true

        resolveLocalIP()
        startListening()
        startSending()

        print("[Discovery] 已启动，接收 UDP \(discoveryPort)")
    }

    func stop() {
        isListening = false
        listenSocket?.cancel()
        sendSocket?.cancel()
        listenSocket = nil
        sendSocket = nil
        devices = []
        print("[Discovery] 已停止")
    }

    // MARK: - 接收

    private func startListening() {
        // 绑定到广播端口，收盒子端的 discover_reply
        listenSocket = NWConnection(host: .ipv4(.any),
                                    port: NWEndpoint.Port(rawValue: discoveryPort) ?? 50002,
                                    using: .udp)
        listenSocket?.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                print("[Discovery] 接收端就绪")
                self?.receiveLoop()
            } else if case .failed(let err) = state {
                print("[Discovery] 接收失败: \(err.localizedDescription)")
            }
        }
        listenSocket?.start(queue: .global(qos: .utility))
    }

    /// ★ 常驻接收循环 —— 盒子任何时候开始广播都能被捕获。
    ///   （这是「手机先开、盒子后开」能扫到的关键）
    private func receiveLoop() {
        listenSocket?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if error == nil, let data, let device = self.parse(data) {
                self.addDevice(device)
            }
            // 无论成功失败都继续收 —— 一次性接收会导致只拿到第一条
            if self.isListening {
                self.receiveLoop()
            }
        }
    }

    // MARK: - 发送查询

    /// 用独立的 socket 发查询，**不能复用接收那个** ——
    /// 复用会把自己的查询包也当成广播收回来。
    private func startSending() {
        sendSocket = NWConnection(host: .ipv4(.any), port: .any, using: .udp)
        sendSocket?.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                print("[Discovery] 发送端就绪")
                // 每 2 秒发一次查询
                self?.scheduleQuery()
            } else if case .failed(let err) = state {
                print("[Discovery] 发送端失败: \(err.localizedDescription)")
            }
        }
        sendSocket?.start(queue: .global(qos: .utility))
    }

    private var queryTimer: DispatchSourceTimer?

    private func scheduleQuery() {
        queryTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 0.3, repeating: 2.0)
        t.setEventHandler { [weak self] in
            self?.sendQuery()
        }
        t.resume()
        queryTimer = t
    }

    /// 发 discover_query 到广播地址。
    ///
    /// ★ 注意：盒子的 50002 端口**只广播、不监听**，
    ///   所以这个查询不会有人回。它只是双保险——
    ///   真正靠「接收循环」捕获盒子的周期广播。
    private func sendQuery() {
        let payload = ControlMessage.build(
            cmd: "discover_query",
            data: ["clientName": UIDevice.current.name]
        )

        // 复用 sendSocket 往广播地址发。
        // ★ 关键：sendSocket 绑在 .any:any（ephemeral 端口），
        //   和接收用的 50002 不是同一个 socket，
        //   所以不会把自己发出去的查询当成盒子广播收回来。
        guard let sendSocket else { return }
        sendSocket.send(
            content: payload,
            to: .ipv4(.broadcast),
            port: 50002,
            completion: .idempotent
        )
    }

    // MARK: - 解析

    /// 解析 discover_reply 广播包
    private func parse(_ data: Data) -> DiscoveredDevice? {
        guard let header = PacketHeader.parse(data),
              header.type == .discoverReply else { return nil }

        let payload = data.dropFirst(KaraokeProtocol.headerSize)
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload))
                as? [String: Any],
              let ip = json["ip"] as? String else { return nil }

        // 同网段过滤：只认 192.168.X.Y 且第三段与手机一致
        guard isSameSubnet(ip) else {
            print("[Discovery] 忽略非同网段设备: \(ip)（本机 \(localIP)）")
            return nil
        }

        return DiscoveredDevice(
            id: ip,
            name: json["name"] as? String ?? "盒子",
            ip: ip,
            audioPort: UInt16((json["port"] as? Int) ?? 50000),
            controlPort: UInt16((json["ctrlPort"] as? Int) ?? 50001)
        )
    }

    private func addDevice(_ device: DiscoveredDevice) {
        DispatchQueue.main.async {
            if let idx = self.devices.firstIndex(where: { $0.id == device.id }) {
                self.devices[idx] = device
            } else {
                self.devices.append(device)
                print("[Discovery] 发现设备: \(device.name) @ \(device.ip)")
            }
        }
    }

    // MARK: - 工具

    /// 判断 targetIP 是否和手机在同一网段
    private func isSameSubnet(_ targetIP: String) -> Bool {
        let t = targetIP.split(separator: ".").compactMap { Int($0) }
        let m = localIP.split(separator: ".").compactMap { Int($0) }
        guard t.count == 4, m.count == 4 else { return false }

        // 只接受 192.168.x.x（家用/办公网段），且第三段一致
        guard t[0] == 192, m[0] == 192 else { return false }
        return t[2] == m[2] && t[3] != m[3]
    }

    /// 解析手机当前的 IPv4 地址
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
                let len = socklen_t(interface.ifa_addr.pointee.sa_len != 0
                                    ? Int(interface.ifa_addr.pointee.sa_len)
                                    : MemoryLayout<sockaddr_in>.size)
                getnameinfo(addr, len, &hostname, socklen_t(hostname.count),
                            nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                if ip.hasPrefix("192.168.") {
                    localIP = ip
                    print("[Discovery] 手机 IP: \(ip)")
                    break
                }
            }
            ptr = interface.ifa_next
        }
    }
}
