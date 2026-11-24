#!/bin/bash
# Собирает Snow.app рядом с этим скриптом. Запуск: bash build.sh
set -e
cd "$(dirname "$0")"

APP="Snow.app"
echo "❄︎ Компилирую…"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

ARCHS=""
if swiftc -O -target arm64-apple-macos12 main.swift Extras.swift -o build/Snow-arm64 2>/dev/null; then ARCHS="$ARCHS build/Snow-arm64"; fi
if swiftc -O -target x86_64-apple-macos12 main.swift Extras.swift -o build/Snow-x86_64 2>/dev/null; then ARCHS="$ARCHS build/Snow-x86_64"; fi
if [ -z "$ARCHS" ]; then
  # покажем настоящие ошибки компиляции
  swiftc -O main.swift Extras.swift -o build/Snow
  ARCHS="build/Snow"
fi
lipo -create $ARCHS -output "$APP/Contents/MacOS/Snow"

echo "❄︎ Рисую иконку…"
if swift icon.swift build/Snow.iconset >/dev/null 2>&1 && iconutil -c icns build/Snow.iconset -o "$APP/Contents/Resources/Snow.icns"; then
  ICON_LINE="<key>CFBundleIconFile</key><string>Snow</string>"
else
  echo "  (иконку сделать не вышло — приложение будет без неё)"
  ICON_LINE=""
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Snow</string>
  <key>CFBundleDisplayName</key><string>Snow</string>
  <key>CFBundleIdentifier</key><string>local.snow.desktop</string>
  <key>CFBundleExecutable</key><string>Snow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>3.1</string>
  <key>CFBundleVersion</key><string>15</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  $ICON_LINE
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
rm -rf build

echo "✅ Готово: $(pwd)/$APP"
echo "   Перетащи его в «Программы» и запускай двойным кликом."
