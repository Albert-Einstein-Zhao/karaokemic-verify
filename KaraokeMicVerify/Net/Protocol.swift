//
//  Protocol.swift
//  雪宝 K歌麦克风 · 极简验证版
//
//  与 docs/雪宝K歌/通信协议_v1.md 和 Android 端 Protocol.kt 严格一致。
//
//  ════════════════════════════════════════════════════════════════════════
//  ★★ 本文件修复了正式版的一个真实协议 bug
//  ════════════════════════════════════════════════════════════════════════
//  正式版 AudioFrameBuilder 里：
//
//      let frameCount = samples.count              // = 960
//      header.frameCount = UInt8(min(frameCount, 255))   // 头里写 255
//      header.payloadLength = UInt32(payloadLength)      // 实际写 1920
//
//  → 头部声明 255 帧，实际携带 960 帧（1920 字节）。
//  → Android 端只读 frameCount×channels×2 = 510 字节，
//     多出的 1410 字节被丢弃 → **每包 87% 的音频数据被扔掉**。
//
//  根因：frameCount 是 u8（协议第32 行明文"最大 255"），
//  但 AudioEngine 的 bufferSize 是 960（20ms）。
//  → 960 根本塞不进 1 字节。
//
//  本版修法：采集粒度直接用 240 帧（5ms，≤255 合法值），
//           并且在 build() 里加**硬断言**，超限直接崩，
//           不再静默截断（静默截断是这次 bug 的根源）。
// ════════════════════════════════════════════════════════════════════════
//

import Foundation

// ════════════════════════════════════════════════════════════════════════
//  常量
// ════════════════════════════════════════════════════════════════════════

enum KaraokeProtocol {
    static let audioPort: UInt16 = 50000
    static let controlPort: UInt16 = 50001
    static let discoveryPort: UInt16 = 50002

    static let magic: UInt16 = 0x4B4D        // "KM"
    static let version: UInt8 = 1
    static let headerSize = 16

    /// frameCount 是 u8，协议硬上限 255。
    /// 255 帧 @48kHz = 5.31ms
    static let maxFrameCount = 255
    static let safeFrameCount = 240          // 5ms，留余量
}

enum PacketType: UInt8 {
    case audio = 0x01
    case ping = 0x02
    case pong = 0x03
    case control = 0x04
    case discoverQuery = 0x05
    case discoverReply = 0x06
    case stats = 0x07
}

/// 16 字节帧头（大端序）
///
/// ```
/// |偏移|长度|类型|字段|
/// |  0 |  2 |u16 | magic = 0x4B4D|
/// |  2 |  1 | u8 | version = 1    |
/// |  3 |  1 | u8 | type          |
/// |  4 |  4 |u32 | seq           |
/// |  8 |  2 |u16 | sampleRate    |
/// | 10 |  1 | u8 | channels      |
/// | 11 |  1 | u8 | frameCount    |
/// | 12 |  4 |u32 | payloadLength |
/// | 16 |  N |bytes| payload       |
/// ```
struct PacketHeader {
    var type: PacketType = .audio
    var seq: UInt32 = 0
    var sampleRate: UInt16 = 48000
    var channels: UInt8 = 1
    var frameCount: UInt8 = 0
    var payloadLength: UInt32 = 0

    func serialize() -> Data {
        var data = Data(capacity: KaraokeProtocol.headerSize)
        data.appendUInt16BE(KaraokeProtocol.magic)
        data.append(KaraokeProtocol.version)
        data.append(type.rawValue)
        data.appendUInt32BE(seq)
        data.appendUInt16BE(sampleRate)
        data.append(channels)
        data.append(frameCount)
        data.appendUInt32BE(payloadLength)
        return data
    }

    /// 解析。返回 nil 表示不是有效包。
    static func parse(_ data: Data) -> PacketHeader? {
        guard data.count >= KaraokeProtocol.headerSize else { return nil }

        var cursor = DataCursor(data: data)
        guard let magic = cursor.readUInt16BE(), magic == KaraokeProtocol.magic else {
            return nil
        }
        _ = cursor.readUInt8()                  // version
        guard let typeRaw = cursor.readUInt8(),
              let type = PacketType(rawValue: typeRaw),
              let seq = cursor.readUInt32BE(),
              let sampleRate = cursor.readUInt16BE(),
              let channels = cursor.readUInt8(),
              let frameCount = cursor.readUInt8(),
              let payloadLength = cursor.readUInt32BE()
        else { return nil }

        return PacketHeader(type: type, seq: seq, sampleRate: sampleRate,
                            channels: channels, frameCount: frameCount,
                            payloadLength: payloadLength)
    }
}

// ════════════════════════════════════════════════════════════════════════
//  音频帧构造
// ════════════════════════════════════════════════════════════════════════

enum AudioFrameBuilder {

    /// Float 采样（-1~1）→ PCM S16LE + 帧头
    ///
    /// ⚠️ 硬断言：frameCount 超过 255 直接触发 fatalError。
    ///    宁可崩溃也不能静默截断 —— 静默截断正是正式版那个 bug 的成因。
    static func build(from samples: [Float], seq: UInt32, sampleRate: UInt16 = 48000) -> Data {
        let frameCount = samples.count

        assert(frameCount <= KaraokeProtocol.maxFrameCount,
               """
               ★ 协议违规：frameCount = \(frameCount)，最大只能是 \(KaraokeProtocol.maxFrameCount)。
                 header.frameCount 是 u8（1 字节），塞不下更大的值。
                 音频引擎的 bufferSize 必须 ≤ \(KaraokeProtocol.safeFrameCount)（\(KaraokeProtocol.safeFrameCount)帧 = 5ms @48kHz）。
                 当前配置会产生「头部声明 N 帧、实际带 M 帧数据」的错位，对端只读 N 帧，
                 多余数据被丢弃 —— 表现为声音断续、极难察觉的音频损失。
               """)

        let payloadLength = frameCount * 2        // Int16 = 2 bytes

        var header = PacketHeader()
        header.type = .audio
        header.seq = seq
        header.sampleRate = sampleRate
        header.channels = 1
        header.frameCount = UInt8(frameCount)     // 现在这个转换是安全的
        header.payloadLength = UInt32(payloadLength)

        var data = header.serialize()
        data.reserveCapacity(KaraokeProtocol.headerSize + payloadLength)

        // Float → Int16（PCM S16LE）
        //
        // ★ 之前这里写的是 vDSP_vclip —— 那个函数签名是
        //   (const Float* 输入, ..., const Float* 下限, const Float* 上限, Float* 输出, ...)
        //   输入输出都必须是 Float，用它写进 [Int16] 是类型错误。
        //   正确做法是 vDSP_vfixu：专用于 Float 数组 → Int16 数组，
        //   超出范围的样本自动饱和钳位（不回绕），这正是我们要的行为。
        var int16Buffer = [Int16](repeating: 0, count: frameCount)

        samples.withUnsafeBufferPointer { src in
            int16Buffer.withUnsafeMutableBufferPointer { dst in
                guard let srcBase = src.baseAddress,
                      let dstBase = dst.baseAddress else { return }
                vDSP_vfixu(srcBase, 1, dstBase, 1, vDSP_Length(frameCount))
            }
        }

        int16Buffer.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            data.append(UnsafeRawBufferPointer(start: base, count: frameCount * 2))
        }

        return data
    }
}

// ════════════════════════════════════════════════════════════════════════
//  控制消息
// ════════════════════════════════════════════════════════════════════════

enum ControlMessage {
    /// 构造控制包（JSON payload）
    static func build(cmd: String, data: [String: Any]? = nil, seq: UInt32 = 0) -> Data {
        var payload: [String: Any] = [
            "cmd": cmd,
            "ts": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let data { payload["data"] = data }

        let json = try? JSONSerialization.data(withJSONObject: payload)
        let jsonBytes = json ?? Data("{}".utf8)

        var header = PacketHeader()
        header.type = .control
        header.seq = seq
        header.payloadLength = UInt32(jsonBytes.count)

        var out = header.serialize()
        out.append(jsonBytes)
        return out
    }
}

// ════════════════════════════════════════════════════════════════════════
//  Data 读写工具
// ════════════════════════════════════════════════════════════════════════

struct DataCursor {
    let data: Data
    var offset: Int = 0

    init(data: Data) { self.data = data }

    mutating func readUInt8() -> UInt8? {
        guard offset < data.count else { return nil }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readUInt16BE() -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        defer { offset += 2 }
        let i = data.startIndex + offset
        return UInt16(data[i]) << 8 | UInt16(data[i + 1])
    }

    mutating func readUInt32BE() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        defer { offset += 4 }
        let i = data.startIndex + offset
        return UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16
                 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
    }
}

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
