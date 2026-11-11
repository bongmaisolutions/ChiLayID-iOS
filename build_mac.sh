#!/usr/bin/env bash
set -e

echo "=========================================================="
echo "  BMSZalo - ChiLayID: Script Tự Động Build iOS Trên macOS "
echo "=========================================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 1. Kiểm tra môi trường Xcode
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Lỗi: Không tìm thấy lệnh xcodebuild."
    echo "👉 Hãy mở Terminal trên Mac và chạy: xcode-select --install"
    exit 1
fi

echo "🍏 Xcode Developer Path: $(xcode-select -p)"

# 2. Tự động sinh Xcode Project nếu có xcodegen
if command -v xcodegen &> /dev/null; then
    echo "⚙️ Đang tạo lại BMSZaloiOS.xcodeproj từ project.yml..."
    xcodegen generate
else
    echo "ℹ️ Dùng trực tiếp BMSZaloiOS.xcodeproj có sẵn trong thư mục."
fi

# 3. Clean và Build cho iOS Device (arm64, hỗ trợ sideload / ad-hoc)
echo "🔨 Đang biên dịch ứng dụng ChiLayID cho iPhone/iPad..."
xcodebuild clean build \
  -project BMSZaloiOS.xcodeproj \
  -scheme BMSZaloiOS \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  AD_HOC_CODE_SIGNING_ALLOWED=YES

# 4. Đóng gói file ChiLayID.ipa
echo "📦 Đang tạo file gói cài đặt ChiLayID.ipa..."
rm -rf Payload ChiLayID.ipa
mkdir -p Payload
cp -R build/Build/Products/Release-iphoneos/BMSZalo.app Payload/ChiLayID.app
zip -r9 ChiLayID.ipa Payload

echo ""
echo "🎉 XUẤT SẮC! File ChiLayID.ipa đã được tạo thành công tại:"
echo "   $SCRIPT_DIR/ChiLayID.ipa"
echo ""
echo "📱 Các cách cài đặt lên iPhone của bạn:"
echo "   1. Sideloadly / AltStore: Kéo file ChiLayID.ipa vào và nhập Apple ID cá nhân."
echo "   2. TrollStore: Mở file ChiLayID.ipa cài đặt trực tiếp không lo thu hồi chứng chỉ."
echo "   3. Xcode: Mở BMSZaloiOS.xcodeproj -> Chọn iPhone của bạn -> Bấm Run (Cmd + R)."
