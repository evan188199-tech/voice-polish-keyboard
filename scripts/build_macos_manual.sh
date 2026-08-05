#!/usr/bin/env bash
# Build macOS companion + IME without xcodebuild package resolution.
# Works under restricted environments by using swiftc + -module-cache-path under /tmp.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export COPYFILE_DISABLE=1

SDK="$(xcrun --sdk macosx --show-sdk-path)"
CACHE="${MODULE_CACHE_PATH:-/tmp/vpk-clang-manual}"
STAGE="${STAGE_DIR:-/tmp/vpk-macos-manual-stage}"
DIST="${DIST_DIR:-$ROOT/dist/macos}"
SHERPA_FW="$ROOT/Vendor/Frameworks/sherpa-onnx.xcframework/macos-arm64_x86_64"
ORT_FW="$ROOT/Vendor/Frameworks/onnxruntime.xcframework/macos-arm64"

mkdir -p "$CACHE" "$STAGE" "$DIST"
rm -rf "$STAGE/VoicePolishMac.app" "$STAGE/VoicePolishInputMethod.app"
mkdir -p \
  "$STAGE/VoicePolishMac.app/Contents/MacOS" \
  "$STAGE/VoicePolishMac.app/Contents/Frameworks" \
  "$STAGE/VoicePolishInputMethod.app/Contents/MacOS"

if [[ ! -d "$SHERPA_FW/SherpaOnnxC.framework" || ! -d "$ORT_FW/onnxruntime.framework" ]]; then
  echo "Vendor frameworks missing. Run ./scripts/prepare_vendor.sh first." >&2
  exit 1
fi

echo "==> Stage frameworks"
ditto --norsrc --noextattr "$SHERPA_FW/SherpaOnnxC.framework" \
  "$STAGE/VoicePolishMac.app/Contents/Frameworks/SherpaOnnxC.framework"
ditto --norsrc --noextattr "$ORT_FW/onnxruntime.framework" \
  "$STAGE/VoicePolishMac.app/Contents/Frameworks/onnxruntime.framework"
./scripts/strip_codesign_detritus.sh "$STAGE/VoicePolishMac.app/Contents/Frameworks"

MOD="$STAGE/modules"
mkdir -p "$MOD"
PREBUILT_MOD="$ROOT/DerivedData/macos/Build/Products/Release"
if [[ -f "$PREBUILT_MOD/SherpaOnnx.o" && -d "$PREBUILT_MOD/SherpaOnnx.swiftmodule" ]]; then
  echo "==> Reuse prebuilt SherpaOnnx module from DerivedData"
  cp -f "$PREBUILT_MOD/SherpaOnnx.o" "$MOD/SherpaOnnx.o"
  rm -rf "$MOD/SherpaOnnx.swiftmodule"
  mkdir -p "$MOD/SherpaOnnx.swiftmodule"
  # cp avoids fileprovider flags that can break ditto under iCloud Documents.
  cp -f "$PREBUILT_MOD/SherpaOnnx.swiftmodule/"* "$MOD/SherpaOnnx.swiftmodule/" 2>/dev/null || true
  xattr -cr "$MOD" 2>/dev/null || true
else
  echo "==> Emit SherpaOnnx module"
  # Produce both object and .swiftmodule next to each other for -I
  swiftc     -module-cache-path "$CACHE"     -sdk "$SDK"     -target arm64-apple-macos14.0     -O     -parse-as-library     -module-name SherpaOnnx     -emit-module     -emit-module-path "$MOD/SherpaOnnx.swiftmodule"     -c     -o "$MOD/SherpaOnnx.o"     -F "$STAGE/VoicePolishMac.app/Contents/Frameworks"     -framework SherpaOnnxC     -framework Foundation     -framework CoreML     Vendor/SherpaOnnxPackage/Sources/SherpaOnnx/SherpaOnnx.swift
fi

echo "==> Build VoicePolishMac (swiftc)"
swiftc   -module-cache-path "$CACHE"   -sdk "$SDK"   -target arm64-apple-macos14.0   -O   -parse-as-library   -module-name VoicePolishMac   -I "$MOD"   -F "$STAGE/VoicePolishMac.app/Contents/Frameworks"   -framework SherpaOnnxC   -framework onnxruntime   -framework SwiftUI   -framework AppKit   -framework AVFoundation   -framework Foundation   -framework Security   -framework ServiceManagement   -framework CoreML   -lc++   -Xlinker -rpath -Xlinker @executable_path/../Frameworks   "$MOD/SherpaOnnx.o"   MacCompanion/MacCompanionApp.swift   MacCompanion/MacAppDelegate.swift   MacCompanion/AppServices.swift   MacCompanion/MenuBarModel.swift   MacCompanion/Services/MacModelSeeder.swift \
  MacCompanion/Services/RightOptionHotkeyService.swift   MacCompanion/Views/MacMainView.swift   MacCompanion/Views/MacSettingsView.swift   MacCompanion/Views/MenuBarContent.swift   Shared/Constants.swift   Shared/Core/AppSettings.swift   Shared/Core/AudioRecorder.swift   Shared/Core/KeyboardBridgeServer.swift   Shared/Core/LocalTextProcessor.swift   Shared/Core/PolishMode.swift   Shared/Core/ASRCompareModels.swift   Shared/Core/AppleOnDeviceTranscriber.swift   Shared/Core/SpeechTranscribing.swift   Shared/Core/TextPolishing.swift   Shared/Core/VocabularyEntry.swift   Shared/Core/OrderedDeliveryCursor.swift   Shared/Core/ChineseScriptConverter.swift   Shared/Core/VoiceSessionCoordinator.swift   Shared/Protocol/BridgeTransport.swift   Shared/Protocol/BuildToken.swift   Shared/Protocol/WireMessage.swift   -o "$STAGE/VoicePolishMac.app/Contents/MacOS/VoicePolishMac"

cat > "$STAGE/VoicePolishMac.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>粤英语音</string>
	<key>CFBundleExecutable</key>
	<string>VoicePolishMac</string>
	<key>CFBundleIdentifier</key>
	<string>com.voicepolish.mac</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>VoicePolishMac</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>用于按住右 Option 进行语音输入识别。</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>用于在当前文本框插入识别结果。</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$STAGE/VoicePolishMac.app/Contents/PkgInfo"

echo "==> Build VoicePolishInputMethod (swiftc)"
swiftc \
  -module-cache-path "$CACHE" \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  -O \
  -module-name VoicePolishInputMethod \
  -framework InputMethodKit \
  -framework AppKit \
  -framework Foundation \
  -framework Carbon \
  MacInputMethod/main.swift \
  MacInputMethod/InputMethodAppDelegate.swift \
  MacInputMethod/VoicePolishInputController.swift \
  MacInputMethod/BridgeSessionClient.swift \
  MacInputMethod/StatusOverlayController.swift \
  Shared/Constants.swift \
  Shared/Core/PolishMode.swift \
  Shared/Protocol/BuildToken.swift \
  Shared/Protocol/WireMessage.swift \
  Shared/Protocol/BridgeTransport.swift \
  Shared/InputMethod/RightOptionStateMachine.swift \
  -o "$STAGE/VoicePolishInputMethod.app/Contents/MacOS/VoicePolishInputMethod"

cat > "$STAGE/VoicePolishInputMethod.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>粤英语音</string>
	<key>CFBundleExecutable</key>
	<string>VoicePolishInputMethod</string>
	<key>CFBundleIdentifier</key>
	<string>com.voicepolish.inputmethod</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>粤英语音</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>MacOSX</string>
	</array>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<string>1</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsSuddenTermination</key>
	<true/>
	<key>InputMethodConnectionName</key>
	<string>com.voicepolish.inputmethod.IMK_Connection</string>
	<key>InputMethodServerControllerClass</key>
	<string>VoicePolishInputController</string>
	<key>TISIconIsTemplate</key>
	<true/>
	<key>TISIntendedLanguage</key>
	<string>zh-Hans</string>
	<key>tsInputMethodIconFileKey</key>
	<string>icon.tiff</string>
	<key>ComponentInputModeDict</key>
	<dict>
		<key>tsInputModeListKey</key>
		<dict>
			<key>com.voicepolish.inputmethod.main</key>
			<dict>
				<key>TISInputSourceID</key>
				<string>com.voicepolish.inputmethod.zh-Hans</string>
				<key>TISIntendedLanguage</key>
				<string>zh-Hans</string>
				<key>tsInputModeScriptKey</key>
				<string>smUnicodeScript</string>
				<key>tsInputModePrimaryInScriptKey</key>
				<false/>
				<key>tsInputModeDefaultStateKey</key>
				<true/>
				<key>tsInputModeIsVisibleKey</key>
				<true/>
				<key>tsInputModeMenuIconFileKey</key>
				<string>icon.tiff</string>
				<key>tsInputModeAlternateMenuIconFileKey</key>
				<string>icon.tiff</string>
			</dict>
		</dict>
		<key>tsVisibleInputModeOrderedArrayKey</key>
		<array>
			<string>com.voicepolish.inputmethod.main</string>
		</array>
	</dict>
</dict>
</plist>
PLIST
printf 'APPL????' > "$STAGE/VoicePolishInputMethod.app/Contents/PkgInfo"
mkdir -p "$STAGE/VoicePolishInputMethod.app/Contents/Resources"
cp -f "$ROOT/MacInputMethod/Resources/icon.tiff" "$STAGE/VoicePolishInputMethod.app/Contents/Resources/icon.tiff"

echo "==> Strip detritus"
./scripts/strip_codesign_detritus.sh \
  "$STAGE/VoicePolishMac.app" \
  "$STAGE/VoicePolishInputMethod.app"
./scripts/fix_macos_embedded_frameworks.sh \
  "$STAGE/VoicePolishMac.app" \
  "$STAGE/VoicePolishInputMethod.app" || true

# Prefer Apple Development, fall back to ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Apple Distribution|Developer ID Application/{print $2; exit}' || true)
if [[ -z "${IDENTITY:-}" ]]; then
  IDENTITY="-"
  echo "NOTE: no development identity visible; ad-hoc signing stage products"
fi

sign_app() {
  local app="$1"
  if [[ -d "$app/Contents/Frameworks" ]]; then
    local fw
    for fw in "$app/Contents/Frameworks"/*.framework; do
      [[ -d "$fw" ]] || continue
      ./scripts/strip_codesign_detritus.sh "$fw"
      codesign --force --sign "$IDENTITY" --timestamp=none "$fw" 2>/dev/null || codesign --force --sign - --timestamp=none "$fw"
    done
  fi
  ./scripts/strip_codesign_detritus.sh "$app"
  codesign --force --deep --sign "$IDENTITY" --timestamp=none "$app" 2>/dev/null || codesign --force --deep --sign - --timestamp=none "$app"
}

echo "==> Sign stage products ($IDENTITY)"
sign_app "$STAGE/VoicePolishMac.app"
sign_app "$STAGE/VoicePolishInputMethod.app"

echo "==> Copy to $DIST"
rm -rf "$DIST/VoicePolishMac.app" "$DIST/VoicePolishInputMethod.app"
ditto --norsrc --noextattr "$STAGE/VoicePolishMac.app" "$DIST/VoicePolishMac.app"
ditto --norsrc --noextattr "$STAGE/VoicePolishInputMethod.app" "$DIST/VoicePolishInputMethod.app"
./scripts/strip_codesign_detritus.sh "$DIST/VoicePolishMac.app" "$DIST/VoicePolishInputMethod.app"
sign_app "$DIST/VoicePolishMac.app"
sign_app "$DIST/VoicePolishInputMethod.app"

echo "Built:"
ls -la "$DIST"
file "$DIST/VoicePolishMac.app/Contents/MacOS/VoicePolishMac"
file "$DIST/VoicePolishInputMethod.app/Contents/MacOS/VoicePolishInputMethod"
