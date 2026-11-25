#!/bin/bash
# 编译 Airhand.ipa（Release，真机 arm64），见 docs/ios.zh-CN.md 的“构建”。
#
#   AIRHAND_SERVER=relay.example.com:4433 AIRHAND_SERVER_FP=<指纹> ios/scripts/build-ipa.sh
#
# 不设 TEAM_ID：生成没有正式签名的 build/Airhand.ipa（只做了 ad-hoc 签名，带着 App Group 等权限），
#   用 Sideloadly / AltStore 之类的工具，或者 `codesign`、企业证书重新签名之后才能装到手机上；
# 设了 TEAM_ID（Apple 开发者账号的团队 ID，Xcode 里登录过这个账号）：用 Xcode 自动签名，
#   EXPORT_METHOD 选 development（默认）/ ad-hoc / app-store-connect / enterprise，生成签好名、能直接安装的 build/export/Airhand.ipa。
set -euo pipefail
cd "$(dirname "$0")/.."
# xcodebuild 的输出只留错误和结果。标准错误输出也并进来（2>&1）：Xcode 在里面打很多无关的 [MT] 日志
# （如没装运行时的模拟器的 DVTAssertions 警告），真正的错误都带“error:”
export PATH="$HOME/.cargo/bin:$PATH"

XCODEGEN="$(command -v xcodegen || echo "$HOME/airhand-ios-setup/xcodegen/bin/xcodegen")"
"$XCODEGEN" generate >/dev/null

SERVER="${AIRHAND_SERVER:-}"
FP="${AIRHAND_SERVER_FP:-}"
[ -z "$SERVER" ] && echo "提示：没有设置 AIRHAND_SERVER，安装后要在“设置”里填服务器地址" >&2

# Rust 核心（真机）
scripts/build-rust.sh iphoneos release

if [ -n "${TEAM_ID:-}" ]; then
  METHOD="${EXPORT_METHOD:-development}"
  rm -rf build/Airhand.xcarchive build/export
  xcodebuild -project Airhand.xcodeproj -scheme Airhand -configuration Release -sdk iphoneos \
    -destination 'generic/platform=iOS' -archivePath build/Airhand.xcarchive \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
    AIRHAND_SERVER="$SERVER" AIRHAND_SERVER_FP="$FP" -allowProvisioningUpdates archive 2>&1 | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"
  cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>$METHOD</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
  xcodebuild -exportArchive -archivePath build/Airhand.xcarchive -exportPath build/export \
    -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates 2>&1 | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"
  echo "已生成：$(pwd)/build/export/Airhand.ipa"
  exit 0
fi

rm -rf build/dd-release build/Payload build/Airhand.ipa
xcodebuild -project Airhand.xcodeproj -scheme Airhand -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath build/dd-release \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  AIRHAND_SERVER="$SERVER" AIRHAND_SERVER_FP="$FP" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

APP=build/dd-release/Build/Products/Release-iphoneos/Airhand.app
mkdir -p build/Payload
cp -R "$APP" build/Payload/
APP=build/Payload/Airhand.app
# ad-hoc 签名并写进权限（App Group）：重新签名的工具据此给扩展和 App 申请同一个 App Group
codesign --force --sign - --entitlements Broadcast/Broadcast.entitlements "$APP/PlugIns/AirhandBroadcast.appex"
codesign --force --sign - --entitlements Airhand/Airhand.entitlements "$APP"
(cd build && zip -qry Airhand.ipa Payload)
rm -rf build/Payload
echo "已生成：$(pwd)/build/Airhand.ipa（未正式签名）"
