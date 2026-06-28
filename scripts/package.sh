#!/usr/bin/env bash
#
# Builds a Release ContainerGUI.app and packages it into a distributable DMG.
#
# Notarization is NOT performed here because it requires your Apple Developer ID.
# After building, sign + notarize with your credentials (see README.md):
#
#   codesign --deep --force --options runtime \
#     --sign "Developer ID Application: <TWOJA NAZWA> (<TEAMID>)" \
#     --entitlements ContainerGUI/ContainerGUI.entitlements \
#     dist/dmg/ContainerGUI.app
#   xcrun notarytool submit dist/ContainerDesktop.dmg --keychain-profile "<PROFILE>" --wait
#   xcrun stapler staple dist/ContainerDesktop.dmg
#
set -euo pipefail
cd "$(dirname "$0")/.."

XCODEGEN="${XCODEGEN:-/opt/homebrew/bin/xcodegen}"
"$XCODEGEN" generate

xcodebuild \
  -project ContainerGUI.xcodeproj \
  -scheme ContainerGUI \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  -clonedSourcePackagesDirPath .spm \
  build

APP=".build/Build/Products/Release/ContainerGUI.app"
DIST="dist"
rm -rf "$DIST"
mkdir -p "$DIST/dmg"
cp -R "$APP" "$DIST/dmg/"
ln -s /Applications "$DIST/dmg/Applications"

hdiutil create \
  -volname "Container Desktop" \
  -srcfolder "$DIST/dmg" \
  -ov -format UDZO \
  "$DIST/ContainerDesktop.dmg"

echo "Gotowe: $DIST/ContainerDesktop.dmg"

# --- Sparkle: appcast ---
# WAŻNE: najpierw podpisz (Developer ID) i znotaryzuj DMG (zob. komentarz na górze),
# DOPIERO POTEM generuj appcast, by wskazywał na notaryzowany plik.
#
# generate_appcast skanuje folder z archiwami aktualizacji, podpisuje je kluczem
# EdDSA z Twojego Keychain (wygenerowanym przez `generate_keys`) i zapisuje appcast.xml.
GEN_APPCAST="$(find .spm -type f -name generate_appcast 2>/dev/null | head -1)"
if [ -n "${GEN_APPCAST}" ]; then
  "${GEN_APPCAST}" "$DIST" \
    --download-url-prefix "https://github.com/sembsa/ContainerDesktop/releases/latest/download/"
  if [ -f "$DIST/appcast.xml" ]; then
    cp "$DIST/appcast.xml" docs/appcast.xml
    echo "Zaktualizowano docs/appcast.xml — zatwierdź i wypchnij (GitHub Pages serwuje go pod SUFeedURL)."
  fi
else
  echo "Uwaga: nie znaleziono generate_appcast — uruchom build (pobiera Sparkle), potem ponów."
fi
