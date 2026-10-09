//
//  Protocol.swift
//  雪宝 K歌麦克风 · iOS 端
//
//  与 Android 端共享的通信协议实现。
//  ⚠️ 本文件必须与 docs/雪宝K歌/通信协议_v1.md 严格一致。
//     任何改动都要同步改另一端，否则联调会失败。
//

import Foundation
import Accelerate

enum KaraokeProtocol {
    static let audioPort: UInt16 = 50000
    static let controlPort: UInt16 = 50001
    static let discoveryPort: UInt16 = 50002

    static let magic: UInt16 = 0x4B4D   // "KM"
    static let version: UInt8 = 1
    static let headerSize: Int = 16

    /// 帧头 frameCount 字段是 u8，硬上限 255 帧。
    /// 音频引擎的 frameSize 必须 ≤ 这个值（实际取 240= 5ms @48kHz）。
    static let maxFrameCount: Int = 255
    /// 推荐值：240 帧 = 5ms @48kHz，留 15 帧余量。
    static let safeFrameCount: Int = 240
}

enum PacketType: UInt8 {
    case audio      = 0x01
    case ping       = 0x02
    case pong       = 0x03
    case control    = 0x04
    case discoverQuery = 0x05
    case discoverReply = 0x06
    case stats      = 0x07
}

/// 通用帧头。
struct PacketHeader {
    var magic: UInt16 = KaraokeProtocol.magic
    var version: UInt8 = KaraokeProtocol.version
    var type: PacketType = .audio
    var seq: UInt32 = 0
    var sampleRate: UInt16 = 48000
    var channels: UInt8 = 1
    var frameCount: UInt8 = 0
    var payloadLength: UInt32 = 0

    /// 序列号比较（处理回绕）。返回 true 表示 a 比 b 新。
    static func isNewer(_ a: UInt32, than b: UInt32) -> Bool {
        Int32(bitPattern: a &- b) > 0
    }
}

extension PacketHeader {
    /// 序列化为 16 字节。
    func serialize() -> Data {
        var data = Data(capacity: KaraokeProtocol.headerSize)
        data.appendBigEndian(magic)
        data.appendBigEndian(version)
        data.append(type.rawValue)
        data.appendBigEndian(seq)
        data.appendBigEndian(sampleRate)
        data.append(channels)
        data.append(frameCount)
        data.appendBigEndian(payloadLength)
        return data
    }

    /// 从数据前16 字节解析。
    init?(parse data: Data) {
        guard data.count >= KaraokeProtocol.headerSize else { return nil }

        let bytes = [UInt8](data.prefix(KaraokeProtocol.headerSize))
        self.magic = bytes.bigEndianUInt16(at: 0)
        self.version = bytes[2]
        self.type = PacketType(rawValue: bytes[3]) ?? .audio
        self.seq = bytes.bigEndianUInt32(at: 4)
        self.sampleRate = bytes.bigEndianUInt16(at: 8)
        self.channels = bytes[10]
        self.frameCount = bytes[11]
        self.payloadLength = bytes.bigEndianUInt32(at: 12)

        // 校验
        guard magic == KaraokeProtocol.magic else { return nil }
        guard payloadLength <= 65535 else { return nil }   // 防御性检查
    }
}

// MARK: - 控制消息

/// 控制面JSON 消息信封。
struct ControlMessage: Codable {
    var cmd: String
    var id: Int?
    var ts: UInt64?
    var data: [String: JSONValue]?

    init(cmd: String, id: Int? = nil, data: [String: JSONValue]? = nil) {
        self.cmd = cmd
        self.id = id
        self.data = data
        self.ts = UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }

    enum ControlCmd {
        static let hello = "hello"
        static let helloAck = "hello_ack"
        static let startAudio = "start_audio"
        static let ready = "ready"
        static let stopAudio = "stop_audio"
        static let bye = "bye"
        static let setVolume = "set_volume"
        static let setParams = "set_params"
        static let stats = "stats"
    }
}

/// 简化的 JSON 值类型（避免引入第三方库）。
///
/// 为什么不用 Codable 的 Any？控制面字段类型固定（数字/字符串/布尔），
/// 自己实现比引第三方 JSON 库更可控，也省去了依赖。
enum JSONValue: Codable {
    case number(Float)
    case string(String)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Float.self) {
            self = .number(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .bool(let v):   try container.encode(v)
        case .null:          try container.encodeNil()
        }
    }

    var floatValue: Float {
        switch self {
        case .number(let v): return v
        case .bool(let v):   return v ? 1 : 0
        case .string(let v): return Float(v) ?? 0
        case .null:          return 0
        }
    }

    var stringValue: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return String(v)
        case .bool(let v):   return v ? "true" : "false"
        case .null:          return ""
        }
    }
}

/// 控制帧构造器。
enum ControlFrameBuilder {
    static func build(_ message: ControlMessage, type: PacketType = .control) -> Data {
        let encoder = JSONEncoder()
        let json = (try? encoder.encode(message)) ?? Data("{}".utf8)

        var header = PacketHeader()
        header.type = type
        header.seq = 0
        header.payloadLength = UInt32(json.count)

        var data = header.serialize()
        data.append(json)
        return data
    }

    static func parse(_ data: Data) -> (PacketHeader, ControlMessage?)? {
        guard let header = PacketHeader(parse: data) else { return nil }
        guard data.count >= KaraokeProtocol.headerSize else { return nil }

        let jsonData = data.dropFirst(KaraokeProtocol.headerSize)
        let decoder = JSONDecoder()
        let message = try? decoder.decode(ControlMessage.self, from: Data(jsonData))

        return (header, message)
    }
}

// MARK: - 音频帧构造

enum AudioFrameBuilder {
    /// 把 Float 采样转换为 PCM S16LE + 帧头。
    /// - Parameters:
    ///   - samples: Float 采样，-1.0 ~ 1.0
    ///   - seq: 序号
    static func build(from samples: [Float], seq: UInt32, sampleRate: UInt32 = 48000) -> Data {
        let frameCount = samples.count

        // ★★★ 协议硬约束：帧头 frameCount 字段是 u8，最大 255（见通信协议_v1.md 第 32 行）。
        // 曾经这里写的是 UInt8(min(frameCount, 255)) —— 而音频引擎取 960 帧，
        // 于是头部声明 255 帧（510 字节）、payloadLength 却按真实 960 帧（1920 字节）算，
        // Android 端只读 510 字节，多出的 1410 字节（73%）被静默丢弃。
        // 症状是「声音基本能听出来，但偶尔断续」—— 极难察觉的音频损失。
        //
        // 现在直接崩掉：静默截断正是这个 bug 的成因，宁可崩也不能带病运行。
        assert(frameCount <= KaraokeProtocol.maxFrameCount, """
        ★ 协议违规：frameCount = \(frameCount)，但帧头 frameCount 字段是 u8，最大 \(KaraokeProtocol.maxFrameCount)。
          症状：Android 端只读 \(KaraokeProtocol.maxFrameCount * 2) 字节，多余的 \((frameCount - KaraokeProtocol.maxFrameCount) * 2) 字节被丢弃。
          修法：把 AudioEngine 的 frameSize 降到 \(KaraokeProtocol.safeFrameCount) 帧（5ms @48kHz）。
        """)

        let payloadLength = frameCount * 2   // Int16 = 2 bytes

        var header = PacketHeader()
        header.type = .audio
        header.seq = seq
        header.sampleRate = UInt16(sampleRate)
        header.channels = 1
        header.frameCount = UInt8(frameCount)   // 断言保证这里安全
        header.payloadLength = UInt32(payloadLength)

        var data = header.serialize()
        data.reserveCapacity(KaraokeProtocol.headerSize + payloadLength)

        // ══════════════════════════════════════════════════════════════
        //  Float → Int16：★ 必须**显式乘满量程** ★
        // ══════════════════════════════════════════════════════════════
        //
        //  ★★★ 这里原本是致命 bug（2026-10-09 从验证版同步修复）★★★
        //
        //  原代码：
        //      vDSP_vclip(src, 1, &scale,                 // scale = 32767.0
        //                 &kNegativeFullScale, &kPositiveFullScale,
        //                 &int16Buffer, 1, frameCount)    // int16Buffer 是 [Int16]
        //
        //  三重错误：
        //   ① vDSP_vclip 是 **float → float** 的裁剪函数，
        //      签名是 (const float*, stride, const float* low, const float* high,
        //              float* out, stride, length)。
        //      它做的是 out[i] = clamp(A[i], B[0], C[0])，**不做任何缩放**。
        //      把 32767 当成「下界」传进去，语义完全不是「乘 32767」。
        //   ② 把 kNegativeFullScale/kPositiveFullScale（Int32）的地址
        //      传给需要 `const float *` 的参数 —— **类型不匹配，根本编译不过**。
        //      也就是说正式版从来没成功编译过一次。
        //   ③ 输出参数要 `float *`，却传了 `[Int16]` 的地址 —— 同样类型不匹配。
        //
        //  验证版里同一个位置的 bug（只调用 floatingPointToInteger 而不乘
        //  32767）导致手机送出去的 Int16 全是 -1/0/1，
        //  电视自然一点声音都没有 —— 排查了整整两轮才发现。
        //  这里的是它的「进化版」，连编译都过不了。
        //
        //  正确做法两步：先乘满量程（vDSP 或 map 都行），
        //  再做浮点→整型转换（自带饱和，超出范围夹到 ±32767 而不是回绕）。
        //
        //  ⚠️ vDSP.floatingPointToInteger **只做四舍五入 + 饱和，不缩放** ——
        //     这一点在 Accelerate 文档里写得含糊，是踩坑的直接原因。
        //     所以那个 `* Float(Int16.max)` 一行都不能省。
        // ══════════════════════════════════════════════════════════════
        let scaled = samples.map { $0 * Float(Int16.max) }
        let int16Buffer = vDSP.floatingPointToInteger(
            scaled,
            integerType: Int16.self,
            rounding: .towardNearestInteger
        )

        // Int16 → 小端字节流
        // ⚠️ Data.append(UnsafeRawBufferPointer) 需要 contentsOf: 标签
        //    （CI 第一次编译报 missing argument label 'contentsOf:'）
        int16Buffer.withUnsafeBufferPointer { src in
            data.append(contentsOf: UnsafeRawBufferPointer(
                start: src.baseAddress!, count: frameCount * 2))
        }

        return data
    }

    /// 把 PCM S16LE 小端字节流解析为 Float 数组。
    static func parseSamples(from data: Data, header: PacketHeader) -> [Float] {
        let payload = data.dropFirst(KaraokeProtocol.headerSize)
        let count = Int(header.frameCount) * Int(header.channels)

        guard payload.count >= count * 2 else { return [] }

        var samples = [Float](repeating: 0, count: count)

        var int16Buffer = [Int16](repeating: 0, count: count)
        payload.withUnsafeBytes { raw in
            _ = raw.baseAddress!.withMemoryRebound(
                to: Int16.self, capacity: count
            ) { src in
                int16Buffer = Array(UnsafeBufferPointer(start: src, count: count))
            }
        }

        // Int16 → Float。
        //
        // ★ vDSP_vflt16 的真实签名是 (Int16*, stride, Float*, stride, N) ——
        //   它**只做类型转换，没有 scale 参数**（CI 首次编译抓出来的 API 幻觉：
        //   原来把 &scale 当第 3 参传了进去，还把 [Float] 传给了 stride 位）。
        //   归一化必须再用 vDSP_vsmul 单独做一步。
        var floatBuffer = [Float](repeating: 0, count: count)
        vDSP_vflt16(int16Buffer, 1, &floatBuffer, 1, vDSP_Length(count))
        var normScale = 1.0 / Float(Int16.max)
        vDSP_vsmul(floatBuffer, 1, &normScale, &samples, 1, vDSP_Length(count))

        return samples
    }
}

// MARK: - Data 扩展（大端序）

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}

extension Array where Element == UInt8 {
    func bigEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func bigEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16
             | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
}

// （原「vDSP_vclip 需要的常量引用」已删除 —— 那个错误的 vDSP_vclip 调用
//   连同这两个 Int32 常量一起被替换成了正确的
//   `samples.map { $0 * Float(Int16.max) }` + `vDSP.floatingPointToInteger`。
//   vDSP.floatingPointToInteger 自带饱和，不需要手工满量程常量。）
