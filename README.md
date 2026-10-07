# 极简验证版 · 使用说明

> 目的：**先验证「这方案到底行不行」，再花钱做完整 UI。**
> 只有 4 个 Swift 文件（DSP 层直接从正式版搬过来，未改动）。

---

## 这版和正式版的区别

| 项目 | 正式版 | 验证版 |
|---|---|---|
| 文件数 | 16 个 | **4 个** |
| 代码行数 | 4568 |约 2400（DSP 1595 + 新增 800） |
| 界面 | 4 个页面，深色影院风 | **单屏**，只有数字和开关 |
| 设备发现 | mDNS 自动发现 | **手填 IP** |
| 断线重连 | 自动 | 无（手动，点「连接」） |
| 帧长 | 960 帧（20ms）⚠️ 见下 | **240 帧（5ms）** |
| 目的| 产品化 | **验证 DSP 效果 + 延迟** |

---

## ★ 顺手修掉了一个真实的协议 bug

正式版 `AudioFrameBuilder` 里：

```swift
let frameCount = samples.count// 960
header.frameCount = UInt8(min(frameCount, 255))   // ← 头里写255
header.payloadLength = UInt32(payloadLength)      // ← 实际写 1920
```

**帧头字段 `frameCount` 是 u8（1 字节，协议文档第 32 行明文「最大 255」），
但音频引擎取 960 帧 —— 960 根本塞不进 1 字节，于是被 `min()` 静默截断成 255。**

后果：
- 头部声明 255 帧（510 字节）
- 实际发出 960 帧（1920 字节）
- Android 端只读 `255×1×2 = 510` 字节，**多出的 1410 字节（73%）被丢弃**
- 听起来可能「基本正常」，只是偶尔断续 —— 属于**极难察觉的音频损失**

修法（本版已做）：
1. 采集粒度直接用 **240 帧（5ms）**，从源头不超限
2. `build()` 里加**硬断言**，超限直接 `fatalError` 并打印诊断信息
   —— 宁可崩溃，也不能静默截断（静默截断正是这个 bug 的成因）

> ⚠️ 正式版 `KaraokeMic_iOS/` 还没改。验证通过后需要同步这个修复。

---

## 怎么编译

> **没有 Mac 也能做** —— 详见 **[Windows部署手册_无Mac版.md](Windows部署手册_无Mac版.md)**
>
> 路径是：源码推 GitHub → Actions 免费 macOS runner 编译出 unsigned.ipa
> → 下载到 Windows → Sideloadly 用免费 Apple ID 签名 → 装进 iPhone。
> 全程 0 元，不需要买 Mac 或开发者账号。
>
> 下面是**有 Mac 时的捷径**，10 秒编完：

```bash
brew install xcodegen          # 只需一次
./build.sh                     # 编译并输出 .app 到 build/
```

### 两种方式对比

| | GitHub Actions | 本地 Mac |
|---|---|---|
| 适合| 没Mac（多数情况） | 有 Mac |
| 耗时 | 12-15 分钟 | 10 秒 |
| 拿到的产物 | unsigned.ipa，需自己签名 | .app，可直接 Run 调试 |
| 能不能看崩溃日志 | ❌ 不能 | ✅ 能 |
| 能不能断点调试 | ❌ 不能 | ✅ 能 |

**结论**：验证效果用 Actions 就够了（UI 上 4 个指标足够判断）。
真要调 DSP 内部逻辑，才值得弄一台 Mac。

### 装到 iPhone

- **没 Mac**：见 Windows 部署手册第四章
- **有 Mac**：打开 `KaraokeMicVerify.xcodeproj` →选你的 iPhone →
  Signing & Capabilities → Team 选你的 Apple ID → Run
  （免费账号即可，App 有效期 7 天，够验证用）

> 免费账号的限制：7 天过期、3 个 App 上限、不能上架。
> **对验证阶段完全够用**，不用买 99 美元/年的开发者账号。

---

## 怎么验证（这是重点）

装好后：盒子保持「K歌麦克风接收器」开启 → iPhone 上输入 `192.168.1.5` → 点「连接」。

然后看这 4 个指标：

### 1. 端到端延迟（最重要）

```
显示 < 120ms →✅ 方案成立，比蓝牙（150-300ms）好一个档次
显示 > 200ms → ⚠️ 检查 Wi-Fi，或改用 5GHz 频段
```

拆解：`RTT/2 + 盒子缓冲 + 输出 20ms`

### 2. AEC 抑制量（回声消除效果）

```
> 10 dB  → ✅ AEC 真的在工作
3-10 dB  → ⚠️ 偏弱，把「AEC 强度」滑到 0.9 再看
≈ 0 dB   → ❌ 没工作，检查参数或参考信号
```

**注意技术边界**：AEC 只能消除「你自己唱的声音」被电视喇叭回放后再次拾取的部分。
**K歌 App 的伴奏漏回拿不到参考信号，消不掉** —— 这是物理限制，不是 bug。

### 3. 啸叫检测

- 显示 `0` →✅ 没检出啸叫
- 显示 `>0` → 看频率是多少Hz，**把手机远离电视**，
  或降低「人声音量」滑块（盒子上那个）

### 4. 输入电平

- 说话/唱歌时应该在 -50~ -10 dB 之间
- 一直显示 `—` → 麦克风没权限，检查设置

### 现场调参

界面下方 4 个开关直接改 DSP 参数，改完立刻生效。
**建议按这个顺序试**：

1. 先关掉啸叫抑制，只开 AEC → 看 ERLE 能到多少（验证 AEC 本体）
2. 打开啸叫抑制 → 听高频是否被削掉太多
3. 加混响（从小房间试起）→ 确认混响能听到但不糊
4. 增益拉到+6dB 左右 → 观察是否容易啸叫

---

## 验证通过之后

```
极简版通过 → 三件事：
1. 把帧长修复同步回正式版 KaraokeMic_iOS/（Protocol.swift + AudioEngine.swift）
2. 记录这版调出来的最优 DSP 参数
3. 正式版UI 开发仍建议买台二手 Mac mini —— 有 Mac 才有断点调试和崩溃日志
```

---

## 文件清单

```
KaraokeMicVerify_iOS/
├── project.yml                      XcodeGen 工程定义
├── build.sh                         本地 Mac 编译脚本
├── Windows部署手册_无Mac版.md    ★ 没 Mac 的人看这个
├── .github/workflows/build-ipa.yml  ★ 无 Mac 编译流水线
├── .gitignore
└── KaraokeMicVerify/
    ├── KaraokeMicVerifyApp.swift     App 入口（9 行）
    ├── ContentView.swift             单屏 UI（指标 + 开关）
    ├── VerifyViewModel.swift         网络 + 音频引擎封装
    ├── Net/
    │   ├── Protocol.swift            协议（★ 修掉 frameCount bug）
    │   └── NetworkController.swift   UDP 发送 + 延迟测量
    ├── Audio/
    │   ├── AudioEngine.swift         采集 + 发送（★ 帧长 240）
    │   ├── SignalChain.swift         10 级 DSP 链（从正式版搬）
    │   ├── AdaptiveEchoCanceller.swift  NLMS 回声消除
    │   ├── HowlingSuppressor.swift      FFT + 陷波器
    │   ├── Reverb.swift                Freeverb 混响
    │   └── Biquad.swift                滤波器基元
    └── Resources/
        └── Info.plist                含三个关键权限
```
