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

//★★★ 必须 import Accelerate
// 下面build() 里的 vDSP_vfixu（Float→Int16 转换）和 vDSP_Length 都在 Accelerate 里，
//  只 import Foundation 会报 "cannot find 'vDSP_vfixu' in scope"。
import Accelerate
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

    /// 输出增益（线性）。
    ///
    /// ★ 为什么是 1.0（2026-10-08 第十三轮，两次误判的记录）
    ///
    /// ⚠️⚠️ 下面这段是**错误的历史注释，被它坑了整整四轮**，保留作警示 ⚠️⚠️
    ///
    ///   旧结论（错）：「Int16 量化把信号全截断成 0」的判断是错的，因为
    ///     Float 0.01 × 32768 = 328  → 远大于最小非零值 1
    ///     iPhone 麦克风正常说话 0.01~0.1 → Int16 值 328~3277，绰绰有余
    ///
    ///   **错在哪**：那段推理隐含了一个前提 —— 代码里存在「× 32768」这个乘法。
    ///   但当时的 `build()` 是把 Float 数组**原样**交给
    ///   `vDSP.floatingPointToInteger`，而这个 API **只做类型转换，不缩放**。
    ///   所以真实结果是：
    ///     Float 0.03（说话） → Int16 0 → -120dBFS
    ///     Float 0.95（吹麦） → Int16 1 → 20*log10(1/32767) = -90.3dBFS
    ///   与用户实测「发送电平全零 / 吹气才 -90 多」逐位吻合。
    ///
    ///   教训：**注释里写「算过一遍没问题」不等于代码里真有那行计算。**
    ///   验证结论时必须对着**实际执行的表达式**，而不是对着注释里的算术。
    ///
    ///   已在 2026-10-09 第二十二轮修复（scaled 处现在显式乘 Float(Int16.max)）。
    ///
    ///   保持 1.0：增益调整应该走「输入增益」滑块（有 UI + 文档），
    ///   不要在协议层偷偷放大。
    static let outputGain: Float = 1.0

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
        // ★★★ 关键修复（2026-10-08 第十三轮）：舍入方式 + 一次误判的记录
        //
        // ① 舍入改成 .toNearestEven（四舍五入）而不是 .towardZero（截断）
        //    截断时 Float 0.6 → Int16 0（直接丢掉）；
        //    四舍五入 Float 0.6 → Int16 1（保留）。
        //    对大信号两者没差别，但对**小信号**是「有」和「无」的区别。
        //
        // ② 曾误判「需要 12 倍增益补偿」，用数值验证后确认**是错的**：
        //      Float 0.01 × 32768 = 328    → 远大于最小非零值 1
        //      Float 0.001 × 32768 = 32.8  → 也够
        //    iPhone 麦克风正常说话 0.01~0.1 → Int16 值 328~3277，绰绰有余。
        //    盒子端阈值 rms > 1e-6 对应 Float 幅度约 0.001（-60 dBFS），
        //    麦克风幅度高出 10~100 倍，**根本不会触发全零**。
        //
        //    真实根因是盒子端缺少播放器线程（jitterBuffer.read() 零调用），
        //    与量化无关 —— 已改在 Android 的 ReceiverService 里修。
        //
        // 所以这里不加增益。outputGain 保持 1.0（见上方注释）。
        // ★★★ 决定性修复（2026-10-09 第二十二轮）★★★
        //
        // 原代码：`vDSP.floatingPointToInteger(samples, ...)` 直接用原始 Float。
        // 但 **vDSP.floatingPointToInteger 只做「类型转换 + 四舍五入 + 饱和」，
        // 它不做任何幅度缩放**。Float 的 -1~1 直接转成 Int16 就只剩 -1/0/1 三个值：
        //
        //     说话 float 0.03  → Int16 0     → -120dBFS（用户看到「全零」）
        //     吹麦 float 0.95  → Int16 1     → 20*log10(1/32767) = -90.3dBFS
        //                                     （用户看到「吹气才有 -90 多」）
        //
        // 盒子端实测日志完全吻合：
        //   【供给诊断】rate=48000样本/秒 peak=0(-120dBFS)
        //   【供给诊断】rate=48000样本/秒 peak=1(-90dBFS)
        // 而对照组 PC 发满幅正弦 peak=26213(-3dBFS) 播放正常 —— 证明盒子端无辜。
        //
        // ⚠️ 之前几轮之所以把量化排除掉，是因为上面 136~140 行那条注释
        //    写着「Float 0.01 × 32768 = 328，远大于最小非零值 1」——
        //    **这个乘法在代码里从来不存在**，注释把人骗了。
        //
        // 修法：Float(-1~1) 必须先乘满量程 32767 再转 Int16。
        //       vDSP 自带饱和裁剪，超过 ±32767 会被安全夹住，不会回绕。
        let fullScale = Float(Int16.max)          // 32767
        let scaled = samples.map { $0 * outputGain * fullScale }

        // ★ 舍入用 .towardNearestInteger（四舍五入），不是 .towardZero（截断）
        //
        //   截断时 Float 0.6 → Int16 0（直接丢掉）；
        //   四舍五入 Float 0.6 → Int16 1（保留）。
        //   对大信号两者没差别，但对**小信号**是「有」和「无」的区别。
        //
        // ⚠️⚠️ vDSP.RoundingMode 只有两个 case：
        //      .towardNearestInteger
        //      .towardZero
        //   **没有** `.toNearestEven`（那是 Python round 的行为名，Swift 这边不一样）。
        //   我第一次写成 .toNearestEven → CI 编译失败（run 37797973451）。
        //   ★ 本机没有 Swift 工具链，这类基础 API 错误无法预先发现，
        //     只能靠 WebSearch 核对 + CI 兜底。
        let int16Buffer = vDSP.floatingPointToInteger(
            scaled,
            integerType: Int16.self,
            rounding: .towardNearestInteger
        )

        // Int16 数组 → 小端字节流。
        // ★ 不要用 data.append(UnsafeRawBufferPointer(...)) ——
        //   那个重载不是所有 SDK 都有，会报 "missing argument label 'contentsOf:'"。
        //   逐元素 append(UInt8(truncatingIfNeeded:)) 最稳，240 个样本的开销可忽略。
        for v in int16Buffer {
            let u = UInt16(bitPattern: v)
            data.append(UInt8(truncatingIfNeeded: u))        // 低字节
            data.append(UInt8(truncatingIfNeeded: u >> 8))     // 高字节
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
