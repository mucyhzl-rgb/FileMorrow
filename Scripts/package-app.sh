#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
build_dir="$project_dir/.build/release"
output_dir="$project_dir/dist"
app_dir="$output_dir/FileMorrow.app"

# Command Line Tools ship SwiftUI headers but not SwiftUIMacros /
# FoundationModelsMacros. @State and @Generable then fail. Prefer full Xcode.
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
elif ! xcrun --find swift >/dev/null 2>&1 || [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  print -u2 "需要完整 Xcode 才能打包 FileMorrow，不能只用命令行工具。"
  print -u2 "1. 从 App Store 安装 Xcode，打开一次并完成组件安装"
  print -u2 "2. 运行: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  print -u2 "3. 再执行: ./Scripts/package-app.sh"
  exit 1
fi

cd "$project_dir"
swift build -c release

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$build_dir/FileMorrow" "$app_dir/Contents/MacOS/FileMorrow"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Assets/FileMorrow.icns" "$app_dir/Contents/Resources/FileMorrow.icns"
cp "$project_dir/Configuration/default-profile.json" "$app_dir/Contents/Resources/default-profile.json"

if [[ -n "${FILEMORROW_SIGN_IDENTITY:-}" ]]; then
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$FILEMORROW_SIGN_IDENTITY" \
    "$app_dir"
else
  codesign --force --deep --sign - "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"
echo "$app_dir"
