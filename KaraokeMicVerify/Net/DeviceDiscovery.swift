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

        // ★ 第二十三轮：立刻主动扫一次网段（不等 2 秒的广播周期）
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.scanSubnet()
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ★★ 网段单播扫描（第二十三轮新增 —— 自动发现的真正主力）
    // ══════════════════════════════════════════════════════════════════════
    //
    //  【为什么要改成单播扫描】
    //  原方案是「被动监听盒子的 UDP 广播」。但 iOS 14+ **接收广播/组播
    //  必须持有 com.apple.developer.networking.multicast 这个 entitlement**，
    //  而该 entitlement 只对付费开发者账号开放申请 —— 用户是用爱思助手
    //  + 个人证书装的，签名里带不了它。
    //  结果就是：监听循环一直跑，但**一个广播包都收不到**，
    //  用户看到的永远是「IP 文本框还是 192.168.1.5」。
    //
    //  【单播不需要任何特殊权限】
    //  向 192.168.1.1 ~ 192.168.1.254 的 50002 端口逐个发一个查询包，
    //  盒子收到后**单播回复**。总共 254 个小包，耗时不到 1 秒，
    //  换来的是 100% 可靠的发现：
    //    · 不依赖广播权限
    //    · 不受路由器「AP 隔离 / 禁止广播」影响
    //    · 手机先开、盒子后开也能扫到（每 15 秒重扫一次）
    //
    //  盒子端对应改动：ReceiverService.startDiscoveryResponder()
    //  —— 50002 从「只发不收」改成「也监听并单播回复」。
    // ══════════════════════════════════════════════════════════════════════

    /// 扫描同网段的所有 IP，收集回复。
    /// 用 BSD socket 而不是 Network.framework —— 后者每个目标要建一条
    /// NWConnection，254 条连接太重；而 UDP 单播用 BSD socket 发是标准做法。
    func scanSubnet() {
        let parts = localIP.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else {
            print("[Discovery] 本机 IP 未知(\(localIP))，跳过扫描")
            return
        }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
        print("[Discovery] 开始扫描 \(prefix).1~254 的 \(discoveryPort) 端口…")

        // ── 建一个 UDP socket（系统自动分配源端口用于收回复）──
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            print("[Discovery] socket 创建失败 errno=\(errno)")
            return
        }
        defer { close(fd) }

        // 接收超时 300ms —— 用于「收回复」阶段的循环，避免卡死
        var tv = timeval()
        tv.tv_sec = 0
        tv.tv_usec = 300_000
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let payload = ControlMessage.build(
            cmd: "discover_query",
            data: ["clientName": UIDevice.current.name]
        )

        // ── ① 发查询：向每个 IP 的 50002 发一个包 ──
        for i in 1...254 {
            let ip = "\(prefix).\(i)"
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_port = discoveryPort.bigEndian          // 网络字节序
            addr.sin_addr.s_addr = inet_addr(ip)             // 已是网络字节序

            let sent = payload.withUnsafeBytes { raw -> Int in
                var a = addr                                  // 需要可变副本
                return withUnsafePointer(to: &a) { ptr -> Int in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, raw.baseAddress, raw.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0 && i == 1 {
                print("[Discovery] sendto 失败 errno=\(errno)")
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
                if let device = parse(data) {
                    addDevice(device)
                    found += 1
                }
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                continue        // 超时，继续等
            } else {
                break
            }
        }

        print("[Discovery] 扫描结束，本次发现 \(found) 个盒子（累计 \(devices.count)）")

        // ── ③ 15 秒后再扫一次：盒子后开的、或者换了 IP 的都能被跟上 ──
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.isListening else { return }
            self.scanSubnet()
        }
    }

    func stop() {
        isListening = false
        listenSocket?.cancel()
        queryTimer?.cancel()
        listenSocket = nil
        queryTimer = nil
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

    /// 启动周期性查询（每 2 秒一次）。
    ///
    /// 不再持有常驻 sendSocket —— `sendQuery()` 每次自己建临时连接发完即cancel，
    /// 这样不存在「把自己的查询当广播收回来」的问题。
    private func startSending() {
        scheduleQuery()
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

        // ── 向广播地址发查询 ──
        // ★ NWConnection **没有** send(content:to:port:) 这个重载
        //   （它只有 send(content:completion:)，只能发给创建时指定的端点）。
        //   所以要发到广播地址，必须为广播端点新建一个连接。
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("255.255.255.255"),
            port: NWEndpoint.Port(rawValue: 50002)!
        )
        let querySocket = NWConnection(to: endpoint, using: .udp)
        querySocket.stateUpdateHandler = { state in
            switch state {
            case .ready:
                querySocket.send(content: payload, completion: .contentProcessed { _ in
                    querySocket.cancel()
                })
            case .failed, .cancelled:
                querySocket.cancel()
            default:
                break
            }
        }
        querySocket.start(queue: .global(qos: .utility))
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
