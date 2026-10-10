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
import Darwin
import Network
import UIKit

/// 连接日志的一行。
///
/// ★ 第二十九轮：之前 connectLog 是 [String]，DeviceView 里用
///   `ForEach(Array(log.enumerated()), id: \.offset)` 渲染。
///   而 connectLog 满了会 removeFirst() —— offset 身份整体位移，
///   SwiftUI 会按旧身份去找已经不存在的下标 → 「index out of range」闪退。
///   「再点一次连接就闪退」有一半是这个原因。
struct LogLine: Identifiable {
    let id = UUID()
    let text: String
    let at: Date = Date()
}

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

    // ── 连接通道 ────────────────────────────────────────────────────
    // ★ 第二十五轮：连接层从 NWConnection 换成裸 BSD UDP socket。
    //
    // 【为什么换】发现（扫描）一直用的是裸 BSD socket，实测手机↔盒子双向通
    //   （盒子日志显示收到手机查询并回复）。但连接用的是 NWConnection ——
    //   它在 iOS 上访问局域网要「本地网络」授权，个人签名包（爱思+Apple ID）
    //   常卡在 .waiting：既不 ready 也不 failed，UI 上就是「点了完全没反应」。
    //   两套机制行为不一致是本次故障的根源，统一成裸 socket 后彻底消除。
    //
    //   UDP 的 connect() 不发任何握手包，只是给 socket 设默认目的地址，
    //   之后 send/recv 都不用再填地址 —— 语义上正是我们想要的「一对一对端」。
    private var audioFd: Int32 = -1        // 音频面：只发（实时线程用）
    private var ctrlFd: Int32 = -1         // 控制面：收发
    /// 目标地址（★ 第二十六轮：改用 sendto 姿势，不再用 connect）
    private var audioTarget = sockaddr_in()
    private var ctrlTarget = sockaddr_in()
    private var controlRunning = false     // 控制接收循环开关
    private let networkQueue = DispatchQueue(label: "com.xuebao.karamic.net", qos: .userInitiated)

    // ★★ 第二十九轮：控制接收循环必须有自己的专用队列。
    //
    // 【在此之前它是跑在 networkQueue 上的】—— 而 networkQueue 是**串行**队列，
    //   接收循环又是一个 `while true { recvfrom }` 永不退出的任务。
    //
    // 这一个决定造成了连锁灾难：
    //   · 首次连接后 networkQueue 被**永久占死**
    //   · 之后提交的 probeReachability() / scanSubnet() **永远排在队尾不执行**
    //     → 用户看到「点连接没反应」
    //   · disconnect() 里 delay 0.3s 的 close(dying) 也永远不执行 → fd 持续泄漏
    //   · 反复重连把 fd 和僵尸线程越堆越多 → 「再点一次就闪退」
    //
    // 修法：接收循环独占一个队列，绝不能和「任务队列」共用。
    private let ctrlQueue = DispatchQueue(label: "com.xuebao.karamic.ctrl")

    /// 代际号：每次新建连接 +1，用它让旧接收循环自然退出。
    ///
    /// ★ 不能用 Bool 开关：第二次连接时 Bool 会被「先置 false 再置 true」，
    ///   旧循环看到的还是 true → 不会退出，反而在**新 fd** 上继续 recv，
    ///   于是两个线程抢同一个 fd。代际号是唯一的，天然避免了这个坑。
    private var ctrlGeneration: UInt64 = 0

    /// 音频线程专用的就绪标记。
    ///
    /// ★ 实时音频线程绝对不能读 `state` —— ConnectionState.failed 携带 String
    ///   payload，主线程写 / 音频线程读 = 引用计数竞争 → EXC_BAD_ACCESS 闪退。
    ///   Bool 是单字节值类型，没有引用计数，跨线程读最多读到旧值，不会崩。
    private var audioReady = false

    /// 连接过程日志（UI 可见 + NSLog 双写）—— 「卡在哪一步」现场定位的唯一手段。
    @Published private(set) var connectLog: [LogLine] = []

    /// UDP 发送姿势体检报告。
    ///
    /// 连不上时最贵的动作是「猜」。这里把几种发送姿势**逐个真发一次**，
    /// 把每种的 errno 摆到 UI 上，一眼看出是「环境拦了」还是「我们自己写错了」。
    @Published private(set) var transportReport: [String] = []

    private var sequence: UInt32 = 0
    private var nextExpectedSeq: UInt32 = 0
    private var pingTimer: Timer?
    private var pingSentAt: [UInt64] = []      // 时间戳队列，用于算 RTT
    private var lastAudioReceivedAt: Date = Date()

    private var currentDevice: DiscoveredDevice?
    private var pendingHelloAck = false

    /// 连接超时定时器（4 秒没 ready 就明确报错，绝不静默卡住）
    func setConnected() {
        helloTimer?.cancel()
        helloTimer = nil
        for item in helloRetryItems { item.cancel() }
        helloRetryItems.removeAll()

        state = .ready
        audioReady = true          // 实时音频线程的就绪标记
        scanning = false           // 已连上，停掉 15 秒一轮的后台重扫
        startPingTimer()
    }

    func clearConnected() {
        audioReady = false
        helloTimer?.cancel()
        helloTimer = nil
        sentSeqSet.removeAll()
        nextExpectedSeq = 0
    }

    /// 实时音频线程专用的发送计数。
    /// ⚠️ 不能直接写 @Published packetsSent：那会每 5ms 触发一次 UI 重算，
    ///    界面会卡成幻灯片。由主线程 ping 定时器每 500ms 同步一次。
    private var sentPacketCount: Int = 0

    /// 音频发送统计（本端）
    private var sentSeqSet: Set<UInt32> = []

    // MARK: - 设备发现

    /// 本机 IPv4 地址（用于确定扫描哪个网段）
    private var localIP: String = ""
    /// Wi-Fi 接口名（en0/en1，由 interfaceSummary 枚举得出）
    private var wifiIface: String = ""
    /// 本机网络接口一句话结论（UI 可见 —— 判断「手机在不在局域网里」）
    @Published private(set) var ifaceSummary: String = "未知"

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
        // ★ 第二十五轮：scanSubnet 内部是「发 254 个包 + 阻塞 recvfrom 等 2 秒」，
        //   之前直接在调用方线程同步执行，而 DeviceView.onAppear 是在**主线程**
        //   调它的 → 进设备页时界面整块卡住约 2 秒，用户反馈「点设备有点慢」。
        //
        //   挪到后台队列：主线程立刻返回，页面秒开；
        //   扫描结果由 handleDiscoveryReply 内部 DispatchQueue.main.async 回主线程刷新，
        //   所以这里是安全的（已确认 scanSubnet 内没有直接改 @Published 状态）。
        networkQueue.async { [weak self] in
            self?.scanSubnet()
        }
    }

    /// 停止扫描。
    func stopDiscovery() {
        // 广播监听（NWListener）已在第二十五轮整体删除 —— 个人签名拿不到
        // multicast entitlement，那条路是死的，这里只需停掉后台重扫即可。
        scanning = false
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

        // ★ 钉到 Wi-Fi：扫描也要防 VPN 抢路由
        pinToWiFi(fd, label: "扫描")

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
            guard var addr = Self.makeAddr(ip: ip, port: KaraokeProtocol.discoveryPort) else {
                continue
            }

            let sent = payload.withUnsafeBytes { raw -> Int in
                return withUnsafePointer(to: &addr) { ptr -> Int in
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

        // ★ 扫描结束必须把状态从 .discovering 复位。
        //   否则 state 永远停在 .discovering，而 UI 的「重新扫描」按钮
        //   只在 state != .discovering 时才显示 → 用户看到的就是
        //   「点重新扫描也没用」。已连接状态不能被误复位，故只动 .discovering。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if case .discovering = self.state {
                self.state = .idle
            }
        }

        // ── ③ 15 秒后再扫一轮：盒子后开的、或者换了 IP 的都能跟上 ──
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.scanning else { return }
            self.scanSubnet()
        }
    }

    /// 解析手机当前的 IPv4 地址（确定扫描网段用）
    private func resolveLocalIP() {
        let (wifi, cellular, all) = interfaceSummary()

        // ★ 第二十七轮：把「手机到底连着什么网」明明白白打进日志。
        //
        // 【为什么必须看这个】排查「手机连不上盒子」时，最容易忽略的就是
        //   **手机自己根本不在局域网里** —— 蜂窝数据、Wi-Fi 掉了、连到别的
        //   路由器、开了 VPN/私有中继，都会让「发往 192.168.1.x 的 UDP」
        //   被内核扔进蜂窝默认路由的黑洞。此时 sendto **照样返回成功**
        //   （内核只是接收了包），但包永远到不了盒子。
        //   只看 sendto 返回值会得出「发出去了，是盒子的问题」的错误结论。
        if let w = wifi {
            localIP = w
            ifaceSummary = "Wi-Fi \(w)"
        } else if let c = cellular {
            ifaceSummary = "⚠️ 只有蜂窝网 \(c)，没有 Wi-Fi 地址"
        } else {
            ifaceSummary = "⚠️ 未检测到任何 IPv4 地址"
        }
        if let c = cellular, wifi != nil {
            ifaceSummary += "；蜂窝 \(c)"
        }
        if !wifiIface.isEmpty {
            ifaceSummary += "（\(wifiIface)）"
        }
        NSLog("[Network] 接口清单: \(all)")
        NSLog("[Network] 本机判定: \(ifaceSummary)")
    }

    /// 枚举所有 IPv4 接口。
    /// - returns: (Wi-Fi 地址, 蜂窝地址, 全部接口清单)
    ///
    /// 接口命名约定（iOS）：`en0` = Wi-Fi，`pdp_ip0` = 蜂窝数据，
    /// `lo0` = 回环，`utun*` = VPN 隧道。看到 utun 就说明用户开着 VPN ——
    /// 而 VPN 会劫持默认路由，很多 VPN 默认不通局域网。
    private func interfaceSummary()
        -> (wifi: String?, cellular: String?, all: String) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return (nil, nil, "getifaddrs 失败")
        }
        defer { freeifaddrs(head) }

        var wifi: String?
        var cellular: String?
        var lines: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first

        while let current = ptr {
            let interface = current.pointee

            // ★ ifa_addr 是可选的，必须先解包
            if let addr = interface.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                // ifa_name 在 Swift 里是 IUO 指针，用 map 解包最稳妥
                let name = interface.ifa_name.map { String(cString: $0) } ?? "?"
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(addr.pointee.sa_len != 0
                                    ? Int(addr.pointee.sa_len)
                                    : MemoryLayout<sockaddr_in>.size)
                getnameinfo(addr, len, &hostname, socklen_t(hostname.count),
                            nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                lines.append("\(name)=\(ip)")

                if name.hasPrefix("en") {
                    // 可能有多个 en*，优先取 192.168./10./172. 这种内网地址
                    if wifi == nil || (ip.hasPrefix("192.168.") && !wifi!.hasPrefix("192.168.")) {
                        wifi = ip
                        wifiIface = name          // ★ 记住接口名，socket 要钉在它上面
                    }
                } else if name.hasPrefix("pdp_ip") {
                    cellular = ip
                }
            }
            ptr = interface.ifa_next
        }
        return (wifi, cellular, lines.joined(separator: " "))
    }

    // ══════════════════════════════════════════════════════════════════
    //  ★★ 接口钉扎（第二十八轮新增 —— 治「VPN 抢默认路由」）
    // ══════════════════════════════════════════════════════════════════
    //
    //  【现象】手机 ping 得通、ARP 也学得到（系统级网络全通），
    //  但 App 里 sendto 照样 EHOSTUNREACH(errno=65)。
    //
    //  【根因】iOS 是「作用域路由」（scoped routing）：手机上只要挂着
    //  任何 VPN/加速器（LetsTAP、UU、小火箭、Cloudflare WARP、iCloud
    //  私有中继……），它们都会建一条 utun 接口并抢走**默认路由**。
    //  普通 App 的 socket 走「默认作用域」→ 包被塞进 utun →
    //  VPN 服务端回「不可达」→ 内核把 EHOSTUNREACH 还给我们。
    //  而 ping 回包是内核在收包接口上直接生成的，不走默认作用域，
    //  所以「ping 得通但 App 发不出」这个矛盾完全成立。
    //
    //  【药方】IP_BOUND_IF：BSD socket 专属的接口钉扎，把 socket 的
    //  路由查找**强制限定在 Wi-Fi 接口**上，utun 再也抢不走。
    //  这是对症下药 —— 不是绕过权限，是把路由作用域钉对地方。
    // ══════════════════════════════════════════════════════════════════
    // ══════════════════════════════════════════════════════════════════
    //  ★★ 安全构造 sockaddr_in（第二十九轮 —— 换掉 inet_addr）
    // ══════════════════════════════════════════════════════════════════
    //
    //  【inet_addr 的坑】它解析失败时返回 INADDR_NONE = 0xFFFFFFFF，
    //  而这个值**正好是合法广播地址 255.255.255.255**，两者无法区分。
    //  用户手输 IP 时只要掺进一个空格/全角字符/换行（输入法很容易做到），
    //  包就变成「往广播发」→ iOS 上没设 SO_BROADCAST，
    //  报出来的 errno 是 EACCES 或 EHOSTUNREACH 这类**误导性**错误，
    //  会直接把排查方向带偏。它还接受 "192.168.1.010" 这种八进制写法。
    //
    //  inet_pton 只接受标准点分十进制，失败就是失败，返回 nil 明确报错。
    // ══════════════════════════════════════════════════════════════════
    private static func makeAddr(ip: String, port: UInt16) -> sockaddr_in? {
        let clean = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian          // 网络字节序（arm64 是小端）

        guard inet_pton(AF_INET, clean, &addr.sin_addr) == 1 else {
            return nil
        }
        return addr
    }

    // ══════════════════════════════════════════════════════════════════
    //  ★★ 接口钉扎 —— 第二十九轮改为「默认关闭 + 结果上 UI」
    // ══════════════════════════════════════════════════════════════════
    //
    //  【第二十八轮的教训】IP_BOUND_IF 是我上一轮为了治「VPN 抢路由」加的，
    //  但它是**自伤**：interfaceSummary() 只按 `hasPrefix("en")` 挑接口，
    //  并没有校验「这个接口上确实挂着通往目标网段的路由」。
    //  一旦钉到不带该路由的接口（iOS 上还有 awdl0/llw0/anpi*/utun* 等），
    //  内核的 ifscope 路由查找失败，**返回的正是 EHOSTUNREACH(65)** ——
    //  和我们看到的 errno 完全一致。
    //
    //  【另一个致命问题】setsockopt 失败时只写了 NSLog，
    //  UI 上一个字都看不到 → 等于闭着眼睛改。
    //
    //  所以这一轮：默认关闭，且结果必须进 UI 日志，由体检报告决定要不要开。
    // ══════════════════════════════════════════════════════════════════
    /// 接口钉扎总开关。体检报告证明「不钉发不出」时才打开。
    private var pinToWiFiEnabled = false

    private func pinToWiFi(_ fd: Int32, label: String) {
        guard pinToWiFiEnabled else { return }
        let name = wifiIface.isEmpty ? "en0" : wifiIface
        let idx = if_nametoindex(name)
        guard idx > 0 else {
            NSLog("[Network] [\(label)] if_nametoindex(\(name)) 失败 errno=\(errno)")
            return
        }
        var index = idx
        // IP_BOUND_IF = 25（netinet/in.h）。不用系统符号名，防 iOS 版本差异。
        let kIPBoundIf: Int32 = 25
        if setsockopt(fd, IPPROTO_IP, kIPBoundIf, &index,
                      socklen_t(MemoryLayout<UInt32>.size)) != 0 {
            NSLog("[Network] [\(label)] IP_BOUND_IF 失败 errno=\(errno)")
        } else {
            NSLog("[Network] [\(label)] socket 已钉到 \(name)（index \(idx)）")
        }
    }

    /// 【保留但已不再作为主要手段】广播 DISCOVER_QUERY 到 255.255.255.255:50002。
    ///
    /// iOS 发出广播不需要权限（收才需要），所以这个包能出去，
    /// 但**收不到回复** —— 收回复需要 multicast entitlement。
    /// 保留它只是为了让局域网内其他类型的客户端仍能发现我们。
    private func handleDiscoveryReply(_ message: ControlMessage) {
        // ★ 第二十五轮：同时兼容「data 嵌套」和「顶层扁平」两种结构。
        //
        // 【为什么要兼容】盒子端旧版把 name/ip/port 放在 JSON 顶层，
        //   这里原来只读 message.data → 收到回复也被 guard 挡掉 return，
        //   设备列表永远是空的，用户看到的就是「点扫描没反应」。
        //   盒子端现已改成双写，这里再加一层兜底，任何一端再改格式都不会静默失效。
        let dict = message.data

        let rawIP = dict?["ip"]?.stringValue ?? message.ip
        let rawName = dict?["name"]?.stringValue ?? message.name

        guard let ip = rawIP, let name = rawName else { return }

        let portValue = dict?["port"]?.floatValue
            ?? message.port
            ?? Float(KaraokeProtocol.audioPort)
        let ctrlValue = dict?["ctrlPort"]?.floatValue
            ?? message.ctrlPort
            ?? Float(KaraokeProtocol.controlPort)
        let version = dict?["appVersion"]?.stringValue ?? message.appVersion ?? "?"

        let pv = Int(portValue)
        let cv = Int(ctrlValue)
        guard pv >= 0, pv <= 65535, cv >= 0, cv <= 65535 else {
            // ★ UInt16(Float) 越界会直接 trap。盒子回一个 port:70000 就把 App 打崩。
            NSLog("[Network] 发现回复里的端口超范围，丢弃：port=\(portValue) ctrl=\(ctrlValue)")
            return
        }
        let port = UInt16(pv)
        let ctrlPort = UInt16(cv)

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
        connectLog.removeAll()
        resolveLocalIP()
        log("开始连接 \(device.name) → \(device.ip):\(device.controlPort)")
        log("手机网络：\(ifaceSummary)")

        // ── 0. 发送姿势体检（穷举，穷举出到底哪种姿势能发）────────────
        probeTransportMatrix(to: device.ip)
        //   用「扫描同款」的 discover_query 打 50002。这一步的成功/失败
        //   能干净地把故障切成两半：
        //     · 探路成功 + hello 无回音 → 网络没问题，是协议/端口的问题
        //     · 探路也失败            → 手机根本发不出 UDP，别再怀疑盒子
        probeReachability(to: device.ip)

        // ── 1. 音频面 socket（只发，实时线程用）──────────────────────
        let aFd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard aFd >= 0 else {
            state = .failed("创建音频 socket 失败")
            return
        }
        // ★ 换成 makeAddr：IP 一旦不合法就明确报错，
        //   而不是像 inet_addr 那样悄悄变成 255.255.255.255 广播包。
        guard let aAddr = Self.makeAddr(ip: device.ip, port: device.port) else {
            close(aFd)
            let msg = "IP 地址不合法：\(device.ip)"
            log("❌ \(msg)")
            state = .failed(msg)
            return
        }
        audioTarget = aAddr
        // 实时音频线程里调 send，绝不能阻塞 → 设为非阻塞
        _ = fcntl(aFd, F_SETFL, fcntl(aFd, F_GETFL, 0) | O_NONBLOCK)
        var sndBuf: Int32 = 262_144
        setsockopt(aFd, SOL_SOCKET, SO_SNDBUF, &sndBuf,
                   socklen_t(MemoryLayout<Int32>.size))
        // ★ 默认不再钉接口（详见 pinToWiFi 的说明）
        pinToWiFi(aFd, label: "音频")
        audioFd = aFd
        log("音频通道就绪 → \(device.ip):\(device.port)")

        // ── 2. 控制面 socket（收发）──────────────────────────────────
        let cFd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard cFd >= 0 else {
            close(aFd); audioFd = -1
            state = .failed("创建控制 socket 失败")
            return
        }
        guard let cAddr = Self.makeAddr(ip: device.ip, port: device.controlPort) else {
            close(aFd); audioFd = -1
            close(cFd)
            let msg = "IP 地址不合法：\(device.ip)"
            log("❌ \(msg)")
            state = .failed(msg)
            return
        }
        ctrlTarget = cAddr

        // ★ 必须显式 bind：UDP socket 只有在**首次 sendto** 时才会被内核
        //   自动绑到一个临时端口。而接收循环是在发 hello **之前**启动的 ——
        //   如果那时 socket 还没有端口，recvfrom 会永远等不到盒子的回包
        //   （绑定到「端口 0」= 没端口，收不到任何东西）。
        //   显式 bind 到 0.0.0.0:0 让内核立刻分配端口，接收才真正生效。
        //   （PC 端 probe_hello.py 也是先 bind 再 sendto —— 已验证可用的姿势。）
        var bindAddr = sockaddr_in()
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_port = 0                 // 让内核分配
        bindAddr.sin_addr.s_addr = 0          // INADDR_ANY
        let bOk = withUnsafePointer(to: &bindAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(cFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bOk != 0 {
            log("❌ 绑定控制端口失败 errno=\(errno) \(Self.errnoText(errno))")
        }
        // 读超时 200ms —— 让接收循环能感知「该退出了」，而不是永久卡在 recv
        var tv = timeval()
        tv.tv_sec = 0
        tv.tv_usec = 200_000
        setsockopt(cFd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))
        // ★ 钉到 Wi-Fi：控制面也要防 VPN
        pinToWiFi(cFd, label: "控制")
        ctrlFd = cFd
        log("控制通道就绪 → \(device.ip):\(device.controlPort)")

        state = .handshaking
        pendingHelloAck = true

        // ── 3. 启动控制面接收循环 ────────────────────────────────────
        startControlReceiveLoop()

        // ── 4. 发 hello（两个 socket 都已就绪，不会像旧版那样把包丢掉）──
        sendHello()
        log("已发送 hello，等待盒子回应…")

        // ★ 第二十七轮：hello 重发 3 次（1.5s / 3.5s / 5.5s）。
        //   UDP 不保证送达，首包丢掉是很常见的事（尤其刚唤醒 Wi-Fi 时）。
        //   只发一次的话，一次偶然丢包就被误判成「盒子无响应」，
        //   白白浪费好几轮排查。重发是 UDP 握手的标准做法。
        for delay in [1.8, 4.0, 6.5] {
            let retry = DispatchWorkItem { [weak self] in
                guard let self,
                      !self.state.isConnected,
                      self.state == .handshaking else { return }
                self.sendHello()
            }
            helloRetryItems.append(retry)
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + delay, execute: retry)
        }

        // ── 5. 超时兜底：8 秒没 ready 就明确报错（放宽到覆盖 3 次重发）──
        helloTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.state.isConnected {
                self.log("❌ 8 秒内没收到盒子回应（已重发 3 次）")
                self.state = .failed("盒子无响应：请确认盒子 App 已打开、且手机与盒子在同一 Wi-Fi")
            }
        }
        helloTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: item)
    }

    // ══════════════════════════════════════════════════════════════════
    //  ★★ UDP 探路（第二十七轮新增 —— 把「手机发不出」和「盒子没回」切开）
    // ══════════════════════════════════════════════════════════════════
    //
    //  故障现场：手机日志停在「已发送 hello」，而盒子端 600 秒监听
    //  **一个包都没收到**。sendto 明明返回成功，包却消失了 ——
    //  说明 sendto 成功 ≠ 包真的出去了（可能被蜂窝默认路由/VPN/权限吞掉）。
    //
    //  探路用的是和「扫描」完全相同的姿势（bind + sendto 到 50002），
    //  而盒子的 50002 已被 PC 探针反复验证过能收能回。
    //  所以这一步的结果是可信的判决：
    //    ✅ 有回音 → 手机→盒子 UDP 通路正常，问题在 hello 本身
    //    ❌ 没回音 → 手机被 iOS 拦了/不在局域网，改盒子没用
    // ══════════════════════════════════════════════════════════════════
    private func probeReachability(to ip: String) {
        networkQueue.async { [weak self] in
            guard let self else { return }

            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else {
                self.log("❌ 探路 socket 创建失败 errno=\(errno)")
                return
            }
            defer { close(fd) }

            var tv = timeval()
            tv.tv_sec = 0
            tv.tv_usec = 300_000
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))

            // ★ 钉到 Wi-Fi：探路结果才代表真实链路
            self.pinToWiFi(fd, label: "探路")

            // 必须 bind —— 没端口就收不到回包
            var bindAddr = sockaddr_in()
            bindAddr.sin_family = sa_family_t(AF_INET)
            bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            bindAddr.sin_port = 0
            bindAddr.sin_addr.s_addr = 0
            withUnsafePointer(to: &bindAddr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            var target = sockaddr_in()
            target.sin_family = sa_family_t(AF_INET)
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_port = KaraokeProtocol.discoveryPort.bigEndian
            target.sin_addr.s_addr = inet_addr(ip)

            let payload = ControlFrameBuilder.build(
                ControlMessage(
                    cmd: "discover_query",
                    data: ["clientName": .string(UIDevice.current.name)]
                ),
                type: .discoverQuery
            )

            let sent = payload.withUnsafeBytes { raw -> Int in
                var t = target
                return withUnsafePointer(to: &t) { p -> Int in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, raw.baseAddress, raw.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            if sent < 0 {
                let why = Self.errnoText(errno)
                self.log("❌ 探路包没发出去：\(why)（errno=\(errno)）")
                return
            }
            self.log("探路包已发出（\(sent) 字节 → \(ip):\(KaraokeProtocol.discoveryPort)）")

            var buf = [UInt8](repeating: 0, count: 4096)
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                let n = recvfrom(fd, &buf, buf.count, 0, nil, nil)
                if n > 0 {
                    if let (header, _) = ControlFrameBuilder.parse(Data(buf[0..<n])),
                       header.type == .discoverReply {
                        self.log("✅ 探路成功：手机→盒子 UDP 可达（盒子有回音）")
                    } else {
                        self.log("⚠️ 收到回音但不是发现回复")
                    }
                    return
                }
                if errno != EAGAIN && errno != EWOULDBLOCK { break }
            }
            self.log("❌ 探路失败：包发出去了但盒子没回音 → 手机被 iOS 拦截或不在同一局域网")
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  ★★ UDP 发送姿势体检（第二十九轮新增 —— 一次性穷举，不再逐个猜）
    // ══════════════════════════════════════════════════════════════════
    //
    //  【为什么要做这个】前面连续三轮都是「改一处 → CI 编译 15 分钟 →
    //   用户手动签名安装 → 还是失败」，每一轮只能验证一个猜想，代价太高。
    //
    //  这一轮改成：把几种发送姿势**逐个真发一次**，errno 原样摆在 UI 上。
    //  一次安装把所有可能性一次性切干净：
    //    · P1 通                      → UDP 本身没问题，是别的地方出错
    //    · P1 不通但 P2 通            → 之前 28 轮的「钉接口」的确是自伤
    //    · UDP 全不通但 P4(TCP) 通    → 整个 App 的 socket 没有本地网络权限
    //    · 全不通，连 P4 也不通       → App 进程的网络栈被彻底隔离
    // ══════════════════════════════════════════════════════════════════
    func probeTransportMatrix(to ip: String) {
        transportReport.removeAll()
        networkQueue.async { [weak self] in
            guard let self else { return }
            let clean = ip.trimmingCharacters(in: .whitespacesAndNewlines)

            var results: [String] = []
            results.append(self.probeUDP(label: "P1 裸sendto", ip: clean,
                                         port: KaraokeProtocol.controlPort,
                                         pinned: false, useConnect: false))
            results.append(self.probeUDP(label: "P2 钉接口sendto", ip: clean,
                                         port: KaraokeProtocol.controlPort,
                                         pinned: true, useConnect: false))
            results.append(self.probeUDP(label: "P3 connect+send", ip: clean,
                                         port: KaraokeProtocol.controlPort,
                                         pinned: false, useConnect: true))
            results.append(self.probeTCPRouting(ip: clean))

            DispatchQueue.main.async {
                self.transportReport = results
            }
        }
    }

    /// 单次 UDP 发送试验，返回一行给人看的结果。
    private func probeUDP(label: String, ip: String, port: UInt16,
                          pinned: Bool, useConnect: Bool) -> String {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            return "\(label)：socket 创建失败 errno=\(errno)"
        }
        defer { close(fd) }

        guard var addr = Self.makeAddr(ip: ip, port: port) else {
            return "\(label)：IP 地址不合法"
        }

        if pinned {
            let name = wifiIface.isEmpty ? "en0" : wifiIface
            if let idx = if_nametoindex(name), idx > 0 {
                var index = idx
                setsockopt(fd, IPPROTO_IP, Int32(25), &index,
                           socklen_t(MemoryLayout<UInt32>.size))
            } else {
                return "\(label)：找不到接口 \(name)（if_nametoindex 失败）"
            }
        }

        let payload = ControlFrameBuilder.build(
            ControlMessage(cmd: "probe",
                           data: ["who": .string(UIDevice.current.name)]),
            type: .control
        )

        var n: Int
        if useConnect {
            n = withUnsafePointer(to: &addr) { p -> Int in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    if Darwin.connect(fd, sa,
                                      socklen_t(MemoryLayout<sockaddr_in>.size)) != 0 {
                        return -1
                    }
                    return payload.withUnsafeBytes { raw -> Int in
                        Darwin.send(fd, raw.baseAddress, raw.count, 0)
                    }
                }
            }
        } else {
            n = payload.withUnsafeBytes { raw -> Int in
                withUnsafePointer(to: &addr) { p -> Int in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, raw.baseAddress, raw.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        guard n >= 0 else {
            let e = errno          // 立刻存，别再被别的调用覆写
            return "\(label)：❌ \(Self.errnoText(e))"
        }
        return "\(label)：✅ 发出 \(n) 字节"
    }

    /// TCP 路由层判定 —— 判断「本地网络权限」的黄金标准。
    ///
    /// 为什么它比 UDP 可靠：UDP 的 sendto 成功只代表内核收下了包，
    /// 不代表路由查找成功。而 TCP 握手要真正完成一次双向往返：
    ///   · connect 成功         → 完整双向 IP 连通
    ///   · ECONNREFUSED         → 对端回了 RST，**证明双向路由完全通**
    ///                            （50001 是盒子的 UDP 口，TCP 去连必然被拒，
    ///                             但能收到 RST 就说明 IP/路由/ARP 全没问题）
    ///   · ETIMEDOUT            → 包发出去了但没人回（被防火墙丢）
    ///   · EHOSTUNREACH         → 路由层失败，和目标是不是开机无关
    private func probeTCPRouting(ip: String) -> String {
        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else {
            return "P4 TCP路由：socket 创建失败 errno=\(errno)"
        }
        defer { close(sock) }

        // 3 秒握手超时，别卡住整个体检
        var tv = timeval()
        tv.tv_sec = 3
        tv.tv_usec = 0
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))

        guard var addr = Self.makeAddr(ip: ip, port: KaraokeProtocol.controlPort) else {
            return "P4 TCP路由：IP 地址不合法"
        }

        let r = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if r == 0 { return "P4 TCP路由：✅ connect 成功——双向 IP 完全连通" }

        let e = errno
        switch e {
        case ECONNREFUSED:
            return "P4 TCP路由：✅ ECONNREFUSED——收到对端 RST，双向路由完全通"
        case ETIMEDOUT:
            return "P4 TCP路由：⚠️ ETIMEDOUT——包发出去了但无人应答（可能被防火墙丢）"
        case EHOSTUNREACH:
            return "P4 TCP路由：❌ EHOSTUNREACH——路由层失败，本机找不到去往该 IP 的路"
        case ENETDOWN:
            return "P4 TCP路由：❌ ENETDOWN——Wi-Fi 网络接口不可用"
        default:
            return "P4 TCP路由：❌ errno=\(e)"
        }
    }

    /// 控制面接收循环（专用队列：阻塞 recv + 200ms 超时轮询）。
    private func startControlReceiveLoop() {
        controlRunning = true

        // ★ 捕获「代际号 + fd」的快照。
        //   循环里只认这两个局部常量，不看实例属性 —— 这样即使又建立了新连接，
        //   老循环也不会跑到新 fd 上去跟别人抢（旧写法用 Bool 开关就会）。
        let gen = ctrlGeneration
        let fd = ctrlFd
        guard fd >= 0 else { return }

        ctrlQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while let self, self.ctrlGeneration == gen {
                let n = recvfrom(fd, &buf, buf.count, 0, nil, nil)
                if n > 0 {
                    self.handleControlPacket(Data(buf[0..<n]))
                } else if n == 0 {
                    // 零长 UDP 包是合法的 —— 但此时 errno 是**上一次调用的脏值**，
                    // 拿它去判断就会误判成超时或错误，必须单独处理。
                    continue
                } else {
                    let e = errno        // 立刻存：NSLog 之类的调用会改 errno
                    if e == EAGAIN || e == EWOULDBLOCK {
                        continue         // 200ms 读超时，正常继续
                    }
                    if e == EBADF { break }   // fd 已被关闭
                    usleep(20_000)            // 未知错误：让出 CPU，避免忙等烧电
                }
            }
            NSLog("[NetworkController] 控制接收循环退出 gen=\(gen)")
        }
    }

    /// 把 errno 翻译成人话 —— 「静默失败」是最难查的故障，必须让人看见。
    private static func errnoText(_ e: Int32) -> String {
        switch e {
        case EPERM:   return "EPERM 操作被拒绝 —— 几乎可以肯定是「本地网络」权限没给（到 iPhone 设置→隐私→本地网络 打开 K歌麦）"
        case EACCES:  return "EACCES 权限不足 —— 请检查「本地网络」权限"
        case ENETDOWN: return "ENETDOWN 网络不可用 —— Wi-Fi 是否断开？"
        case ENETUNREACH: return "ENETUNREACH 网络不可达 —— 手机和盒子不在同一网段"
        case EHOSTUNREACH: return "EHOSTUNREACH 主机不可达 —— 盒子 IP 是否变了？"
        case ENOTCONN: return "ENOTCONN socket 未连接（sendto 姿势下不应出现）"
        case EADDRNOTAVAIL: return "EADDRNOTAVAIL 地址不可用 —— IP 填写有误？"
        case EAFNOSUPPORT: return "EAFNOSUPPORT 地址族不支持"
        case EMSGSIZE: return "EMSGSIZE 包太大"
        case ENOBUFS:  return "ENOBUFS 发送缓冲满"
        case EAGAIN:   return "EAGAIN 暂时无法发送（非阻塞 socket 缓冲满）"
        default:       return "errno=\(e)"
        }
    }

    /// 写一行连接日志（UI 可见 + NSLog 双写）。
    private func log(_ text: String) {
        NSLog("[Connect] \(text)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectLog.append(LogLine(text: text))
            if self.connectLog.count > 12 { self.connectLog.removeFirst() }
        }
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

    private func handleControlPacket(_ data: Data) {
        guard let (header, message) = ControlFrameBuilder.parse(data) else { return }

        // ★★ 第二十九轮补上的一行 —— 这才是最要命的漏网之鱼。
        //
        // 【在此之前】lastAudioReceivedAt 只在属性声明时初始化过一次，
        //   全项目再也没有任何地方给它赋值。于是 App 运行超过 2 秒后，
        //   checkConnectionHealth() 里的
        //       Date().timeIntervalSince(lastAudioReceivedAt) > 2.0
        //   **恒为真**。结果就是：任何一次成功连接，
        //   最多活 1 秒就会被判「连接超时」掐断。
        //   不修这条，就算这一轮连上了，也立刻会掉。
        lastAudioReceivedAt = Date()

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
            self.log("收到 hello_ack，请求盒子开始接收")
            let bufferMs = msg.data?["bufferMs"]?.floatValue ?? 40
            DispatchQueue.main.async {
                self.bufferFillMs = bufferMs
            }
            sendControl(ControlMessage(cmd: ControlMessage.ControlCmd.startAudio, id: 2))

        case ControlMessage.ControlCmd.ready:
            // 盒子已预填充缓冲，可以正式开始
            self.log("✅ 盒子已就绪，开始传送人声")
            DispatchQueue.main.async {
                self.setConnected()
            }

        case "error":
            let err = msg.data?["error"]?.stringValue ?? "unknown"
            DispatchQueue.main.async {
                self.clearConnected()
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
    /// ⚠️ 这里读的是 audioReady（Bool），**不是** state。
    ///   ConnectionState.failed 携带 String payload，主线程写 / 音频线程读
    ///   会构成引用计数的并发竞争 → EXC_BAD_ACCESS 闪退。
    ///   Bool 没有引用计数，最坏情况是读到上一帧的旧值，不会崩。
    func sendAudioFrame(samples: [Float], sampleRate: UInt32 = 48000) {
        guard audioFd >= 0, audioReady else { return }

        let packet = AudioFrameBuilder.build(
            from: samples, seq: sequence, sampleRate: sampleRate
        )

        // ⚠️ 实时音频线程：这里只允许有一次 send 系统调用。
        //    不能碰 @Published、不能 DispatchQueue.main、不能加锁等待，
        //    否则 UI 每 5ms 被唤醒一次，界面会卡成幻灯片。
        var target = audioTarget
        let n = packet.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &target) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(audioFd, raw.baseAddress, raw.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if n > 0 { sentPacketCount &+= 1 }
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
            "t0": .number(Float(t0 & 0xFFFFFFFF))
        ])
        sendControl(msg)

        // 把实时线程累加的计数同步给 UI（主线程，每 500ms 一次，不会卡）
        packetsSent = sentPacketCount
    }

    private func handlePong(_ data: Data) {
        guard let (header, message) = ControlFrameBuilder.parse(data) else { return }
        let t0Double = message?.data?["t0"]?.floatValue ?? 0
        // ★ 数据来自网络：负值 / NaN 直接喂给 UInt64() 会 trap（可被远端打崩）
        guard t0Double >= 0, t0Double.isFinite else { return }
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
        guard ctrlFd >= 0 else {
            NSLog("[NetworkController] 控制 socket 未建立，丢弃 cmd=\(message.cmd)")
            return
        }
        let data = ControlFrameBuilder.build(message)
        var target = ctrlTarget
        let n = data.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &target) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(ctrlFd, raw.baseAddress, raw.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if n < 0 {
            // ★ errno 必须在系统调用后**立刻**取。
            //   NSLog 本身是一次系统调用，很可能把 errno 覆写掉 ——
            //   旧写法在 NSLog 之后再读一次 errno，那个值已经不可信了。
            let e = errno
            let why = Self.errnoText(e)
            NSLog("[NetworkController] 控制发送失败 cmd=\(message.cmd) errno=\(e) \(why)")
            log("❌ 发送 \(message.cmd) 失败：\(why)（errno=\(e)）")
        } else if message.cmd == ControlMessage.ControlCmd.hello {
            log("hello 已发出（\(n) 字节，sendto 成功）")
        }
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
        helloTimer?.cancel()
        helloTimer = nil
        // ★ 之前只 cancel 了 helloTimer，重发 hello 的定时器没人管：
        //   断开之后它们照样到点执行 sendHello()，往一个新的连接里塞脏包。
        for item in helloRetryItems { item.cancel() }
        helloRetryItems.removeAll()

        // 礼貌告别（此时 ctrlFd 还有效）
        if ctrlFd >= 0 {
            sendControl(ControlMessage(cmd: ControlMessage.ControlCmd.bye))
        }

        // ★ 代际号 +1：让仍在跑的旧接收循环自然退出
        ctrlGeneration &+= 1
        audioReady = false
        controlRunning = false

        if audioFd >= 0 { close(audioFd); audioFd = -1 }

        // ★ 直接关，不再延迟 0.3 秒。
        //   旧写法是把 close 丢给 networkQueue.asyncAfter —— 而 networkQueue
        //   早就被接收循环永久占死了（详见 ctrlQueue 的说明），
        //   这个 close **从来就没有执行过**，于是每次重连都泄漏一个 fd，
        //   反复几次就把 fd 堆到上限 —— 「再点一次就闪退」就是从这来的。
        //
        //   Darwin 上关闭一个正在 recvfrom 的 fd 是安全的（recv 立刻返回
        //   EBADF），因为没有 **已有**
        if ctrlFd >= 0 { close(ctrlFd); ctrlFd = -1 }

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


}
