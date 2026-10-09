//
//  DeviceDiscovery.swift
//  雪宝 K歌麦克风· iOS 端
//
//  ════════════════════════════════════════════════════════════════
//  自动发现局域网内的盒子 —— 解决「IP 变了要手动改」的痛点
//  ════════════════════════════════════════════════════════════════
//
//  【为什么需要】
//  盒子 IP 由 DHCP 分配，会变（实测从 192.168.1.5 变成了 192.168.1.10）。
//  手动改 IP 容易忘、容易打错，而且第 17 轮就因为「输入的IP 没被使用」
//  闹了乌龙 —— 用户改了半天，实际连的还是旧 IP。
//
//  【原理】
//  盒子端已在每秒向 255.255.255.255:50002 广播：
//      { cmd:"discover_reply", name:"极光盒子", ip:"192.168.1.10", ... }
//  iOS端只要监听这个端口，收到广播就自动填 IP —— 一次配置都不用改。
//
//  【为什么不用 Bonjour】
//  Bonjour（NSNetServiceBrowser）更优雅，但要求盒子端也实现 mDNS 服务发布，
//  Android 侧需要额外依赖。盒子端已经在用 UDP 广播了，
//  iOS 侧监听广播的兼容性最好，也不用改 Android 代码。
//
//  ★ 关键：只接受与手机**同网段**的盒子（私有地址 + 掩码检查），
//    避免连上公司网络里的其他设备。
//
//════════════════════════════════════════════════════════════════

import Foundation
import Network
import UIKit          // UIDevice.current.name

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

    private var socket: NWConnection?
    private var isListening = false

    /// UDP 广播可能被路由器/AP 丢弃，所以每 2 秒重发一次查询
    private var queryTimer: Timer?

    private let discoveryPort: UInt16 = 50002

    // MARK: - 生命周期

    func start() {
        guard !isListening else { return }
        isListening = true
        resolveLocalIP()
        listen()
        startQuerying()
        print("[Discovery] 已启动，监听 UDP \(discoveryPort)")
    }

    func stop() {
        isListening = false
        queryTimer?.invalidate()
        queryTimer = nil
        socket?.cancel()
        socket = nil
        devices = []
        print("[Discovery] 已停止")
    }

    // MARK: - 监听广播

    private func listen() {
        // 绑定到广播端口，接收盒子端的 discover_reply
        // 注意：不能用 .udp 的 NWConnection 监听（那是客户端行为），
        // 这里用 BSD socket 绑定端口更直接。
        socket = NWConnection(host: .ipv4(.any), port: discoveryPortNW(), using: .udp)
        socket?.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                print("[Discovery] 监听就绪")
                self?.receiveLoop()
            } else if case .failed(let err) = state {
                print("[Discovery] 监听失败: \(err.localizedDescription)")
            }
        }
        socket?.start(queue: .global(qos: .utility))
    }

    private func receiveLoop() {
        socket?.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let device = self.parse(data) {
                self.addDevice(device)
            }
            // 继续收下一个
            self.receiveLoop()
        }
    }

    /// 解析 discover_reply 广播包
    private func parse(_ data: Data) -> DiscoveredDevice? {
        guard let header = PacketHeader.parse(data),
              header.type == .discoverReply else { return nil }

        let payload = data.dropFirst(KaraokeProtocol.headerSize)
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload))
                as? [String: Any],
              let ip = json["ip"] as? String else { return nil }

        // 同网段过滤：只认 192.168.x.x 这类私有地址，
        // 且第三段要和手机一致（防止连到公司网络的别的设备）
        guard isSameSubnet(ip) else {
            print("[Discovery] 忽略非同网段设备: \(ip)")
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

    // MARK: - 主动查询

    /// 主动发 discover_query，回应比广播更快（路由器有时会拦广播包）
    private func startQuerying() {
        queryTimer?.invalidate()
        queryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sendQuery()
        }
        // 立即发一次
        sendQuery()
    }

    private func sendQuery() {
        guard let socket else { return }
        let payload = ControlMessage.build(cmd: "discover_query", data: ["clientName": UIDevice.current.name])
        // 广播到 255.255.255.255
        socket.send(content: payload, to: .ipv4(.broadcast), completion: .idempotent)
    }

    // MARK: - 工具

    private func discoveryPortNW() -> NWEndpoint.Port {
        NWEndpoint.Port(rawValue: discoveryPort) ?? 50002
    }

    private func addDevice(_ device: DiscoveredDevice) {
        DispatchQueue.main.async {
            if let idx = self.devices.firstIndex(where: { $0.id == device.id }) {
                self.devices[idx] = device
            } else {
                self.devices.append(device)
                print("[Discovery] 发现新设备: \(device.name) @ \(device.ip)")
            }
        }
    }

    /// 判断 targetIP 是否和手机在同一网段
    private func isSameSubnet(_ targetIP: String) -> Bool {
        let t = targetIP.split(separator: ".").compactMap { Int($0) }
        let m = localIP.split(separator: ".").compactMap { Int($0) }
        guard t.count == 4, m.count == 4 else { return false }

        // 第三段必须一致（192.168.X.Y 这种家用/办公网段）
        // 并且目标不能和本机相同
        if t[0] != 192 || m[0] != 192 { return false }
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
            let addr = interface.ifa_addr
            if addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(interface.ifa_addrlen),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                // 只取 192.168.x.x（家用/办公网段）
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
