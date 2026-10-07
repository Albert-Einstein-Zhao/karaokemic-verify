#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
#  雪宝 K歌麦克风 · 验证版 —— 编译脚本（在云 Mac / 借来的 Mac 上跑）
# ══════════════════════════════════════════════════════════════════════
#
#  用法：
#    ./build.sh            编译并输出 .app 到 build/
#    ./build.sh --run      编译并安装到连接的 iPhone
#
#  前置条件（在 Mac 上执行一次）：
#    brew install xcodegen
#
#  签名（用免费 Apple ID 即可，不需要付费开发者账号）：
#    在 Xcode 里 Product → Destination 选你的 iPhone，
#    然后 Signing & Capabilities → Team 选你的 Apple ID。
#    首次可能要在 iPhone 上「信任」你的开发者证书。
# ══════════════════════════════════════════════════════════════════════

set -e

cd "$(dirname "$0")"
PROJECT="KaraokeMicVerify.xcodeproj"
SCHEME="KaraokeMicVerify"

if ! command -v xcodegen &> /dev/null; then
    echo "❌ 没装 XcodeGen。执行： brew install xcodegen"
    exit 1
fi

echo "▸ 生成 Xcode 工程..."
xcodegen generate

echo "▸ 查找已连接的 iPhone..."
DEVICE=$(xcrun xctrace list devices 2>/dev/null \
    | grep -iE "iPhone" \
    | grep -v "Simulator" \
    | head -1 | sed -E 's/.*\((.*)\).*/\1/')

if [ -z "$DEVICE" ]; then
    echo "⚠️  没检测到 iPhone。将用通用 iOS 目标编译（不安装）。"
    DEST="generic/platform=iOS"
else
    echo "▸ 目标设备：$DEVICE"
    DEST="id=$DEVICE"
fi

echo "▸ 编译（不签名的通用构建，最快）..."
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "$DEST" \
    -derivedDataPath ./build \
    CODE_SIGNING_ALLOWED=NO \
    build

echo ""
echo "✅ 编译完成。产物在："
find ./build -name "*.app" -maxdepth 5 -exec echo "   {}" \;

if [ "$1" == "--run" ] && [ -n "$DEVICE" ]; then
    echo ""
    echo "▸ 安装到 $DEVICE..."
    APP=$(find ./build -name "$SCHEME.app" -maxdepth 5 | head -1)
    if [ -n "$APP" ]; then
        # 需要先在 Xcode 里配好签名才能真机安装
        echo "⚠️  真机安装需要签名。建议在 Xcode 里打开 $PROJECT 直接 Run。"
    fi
fi
