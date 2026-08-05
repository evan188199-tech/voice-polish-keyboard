# 粤英语音键盘 (Voice Polish Keyboard)

Personal voice input for **iOS 18+** and **macOS 14+ (Apple Silicon)**:

- **Hold-to-talk**: iOS keyboard button / macOS **Right Option**
- **On-device ASR**: sherpa-onnx + SenseVoiceSmall INT8 (`zh/en/ja/ko/yue`)
- **Optional polish modes**: OpenAI-compatible `/v1/chat/completions` with 4 modes — **只纠错 / Coding / 润色词句 / 问 LLM** (settings + keyboard/IME cycle: 关 → 纠错 → 代码 → 润色 → 问答 → 关)
- Main / companion app owns mic + recognition; keyboard or InputMethodKit only controls & inserts text
- Loopback TCP bridge on `127.0.0.1:52741-52743` (no App Group; free Apple ID friendly)

## Status (2026-08-05)

- iOS project builds with Xcode-beta / iOS SDK
- macOS companion + InputMethodKit input method targets added (self-use, arm64, no notarization)

## Requirements

- Xcode 16+ / Xcode-beta with iOS 18+ and macOS 14+ SDKs
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Personal Team ID (default in `project.yml`: `45LB5X3XTW`)
- Apple Silicon Mac for the macOS port
- First run: Wi-Fi recommended for ~230 MB model download (or seed from `Vendor/Models`)

## Architecture

| Component | Role |
|-----------|------|
| `VoicePolishApp` | iOS mic session, sherpa-onnx ASR, optional polish API, bridge server |
| `Keyboard` | iOS keyboard extension (hold / swipe-cancel / insertText) |
| `MacCompanion` (`VoicePolishMac`) | macOS menu-bar companion: mic, model, polish, bridge, settings |
| `MacInputMethod` | InputMethodKit: Right Option PTT → insert at caret |
| `Shared` | Protocol, build token, ASR/polish core, Right Option state machine |
| `Vendor/SherpaOnnxPackage` | Local SPM wrapper around vendored xcframeworks |

Bridge commands: `ping` / `start` / `finish` / `cancel` / `status` / `setPolishEnabled` / `setPolishMode` / `cyclePolishMode` / `setChineseScript`  
Status may include `polishEnabled` + `polishMode` + optional `jobID` / `pendingCount` / `chineseScript`. Responses may include machine-readable `errorCode` (`companionNotRunning`, `micDenied`, `modelNotReady`, `inputSessionInvalid`, …).

### Multi-segment async pipeline

- Releasing the mic **enqueues** a job immediately; you can hold again while earlier segments are still recognizing or polishing.
- Local SenseVoice runs **FIFO (concurrency 1)**; cloud polish runs with **max concurrency 2**.
- Cloud may finish out of order, but text is **inserted in speaking order**.
- Swipe-left / Escape cancels only the current capture; closing the voice session cancels the in-memory queue.
- `finish` returns `.ok` + `jobID` quickly; clients poll `status` (optionally with `jobID`) for the ordered result.

### Polish modes

| Mode | Short | Behavior |
|------|-------|----------|
| 只纠错 | 纠错 | Fix ASR errors + punctuation only; do not answer questions |
| Coding | 代码 | Clean spoken coding intent; preserve identifiers/paths |
| 润色词句 (default) | 润色 | Current faithful oral cleanup; do not answer questions |
| 问 LLM | 问答 | Treat transcription as question or instruction; insert **only final answer** (e.g. “请用英语输出『…』” → English sentence). On failure, fall back to local transcription |

Quick cycle (keyboard chip / IME menu): **关 → 纠错 → 代码 → 润色 → 问答 → 关**.


### Model paths

- iOS: `Documents/SenseVoiceModels/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/`
- macOS: `~/Library/Application Support/VoicePolishKeyboard/SenseVoiceModels/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/`

## Vendor binaries

Large binaries are gitignored:

- `Vendor/Frameworks/*.xcframework` (sherpa-onnx + onnxruntime; iOS + macOS slices when prepared)
- `Vendor/Models/...` (SenseVoice INT8)

Prepare / repair local frameworks:

```bash
./scripts/prepare_vendor.sh
```

## iOS build & install

```bash
cd /Users/shoushu/Documents/github/voice-polish-keyboard
./scripts/install_device.sh   # auto-select connected iPhone; or pass device id
# unlock the iPhone, then:
xcrun devicectl device process launch --device <device-id> com.voicepolish.app
```

Optional model seed from Mac:

```bash
./scripts/seed_model_to_device.sh   # auto-select, or pass device id
```

### iOS first-run checklist

1. Unlock phone and open **粤英语音键盘**
2. Download or load SenseVoice model (~230 MB)
3. Grant microphone
4. Tap **启动语音会话**
5. Hold the mic button: 普通话/粤语/English mix → release to recognize
6. Settings → add keyboard → enable **Allow Full Access**
7. Optional: set OpenAI-compatible polish API key and pick a polish mode

## macOS build & install (self-use)

```bash
./scripts/prepare_vendor.sh   # once, needs network
./scripts/install_macos.sh    # full rebuild + install (preferred when Xcode is free)
# or, if dist/macos already has products (faster):
ALLOW_ADHOC_SIGN=1 ./scripts/install_from_dist.sh
# or double-click install-macos.command

# If 粤英语音 is missing from System Settings after install, run in normal Terminal:
./scripts/activate_ime.sh
```

What the install script does:

1. `xcodegen generate`
2. Builds signed `VoicePolishMac` + `VoicePolishInputMethod` (arm64)
3. Installs companion to `~/Applications/VoicePolishMac.app`
4. Installs input method to `~/Library/Input Methods/VoicePolishInputMethod.app`
5. Seeds model into Application Support when `Vendor/Models` is present
6. Opens the companion app

### macOS first-run checklist

**推荐自用路径（不依赖输入法列表，macOS 27 beta 更稳）：**

1. 运行 `./scripts/fix_macos_selfuse.sh`（普通 Terminal.app）
2. **Privacy → Microphone** 与 **Privacy → Accessibility** 勾选 **粤英语音**
3. 菜单栏显示「就绪」后，在任意文本框 **按住右 Option 说话 → 松开粘贴**

**可选：系统输入法路径（TIS 能扫到时）**

1. **System Settings → Privacy & Security → Microphone** → allow **粤英语音** / VoicePolishMac
2. **System Settings → Keyboard → Text Input → Edit… → +** → add **粤英语音**
3. Switch to that input source in the menu bar
4. Open companion menu bar app → download/load model → **启动语音会话**
5. In TextEdit / Notes / Safari / Terminal: hold **Right Option**, speak, release → text inserts at caret
6. **Escape** cancels an in-progress recording

Login-at-launch is **on by default** (toggle in companion Settings).

### macOS：关闭输入法 / 恢复正常输入

「粤英语音」有两层，别混在一起：

| 组件 | 作用 | 如何关掉 |
|------|------|----------|
| **伴随应用** `VoicePolishMac`（菜单栏） | 麦克风、识别、右 Option 全局监听 | 菜单栏关闭「右 Option 语音监听」/「停止语音会话」/「退出伴随应用」 |
| **系统输入法** `VoicePolishInputMethod` | 可选，用于输入法插字 | 切到双拼/ABC，或运行 `./scripts/disable_ime.sh` |

**推荐自用：不必常驻在系统输入法上。** 保持菜单栏伴随应用「就绪」，用右 Option 即可。

#### 立刻恢复打字（卡住 / 切不走 / 不能语音）

```bash
# 双击也可：disable_ime.command
./scripts/disable_ime.sh --stop-companion
```

或菜单栏 **粤英语音 → 关闭输入法 / 恢复正常输入**。

然后：

1. 点菜单栏输入法图标，选 **双拼 / ABC**（常见快捷键 **Control+空格**）
2. 若列表里仍有「粤英语音」且异常：系统设置 → 键盘 → 文本输入 → 编辑… → 去掉它
3. 需要语音时再打开 `~/Applications/VoicePolishMac.app`，确认麦克风 + 辅助功能权限

#### 只关语音、不卸输入法

- 菜单栏关闭 **右 Option 语音监听**
- 或 **停止语音会话**（会话停后右 Option 不会开录）

#### 卸载输入法二进制

```bash
./scripts/disable_ime.sh --remove
# 或完整卸载见下方 uninstall
```

### macOS uninstall


```bash
rm -rf ~/Applications/VoicePolishMac.app
rm -rf ~/Library/Input\ Methods/VoicePolishInputMethod.app
rm -rf ~/Library/Application\ Support/VoicePolishKeyboard
```

Then remove the input source in System Settings → Keyboard → Text Input.

### macOS troubleshooting

| Symptom | What to try |
|---------|-------------|
| Right Option does nothing | Confirm input source is **粤英语音**; companion shows **就绪** |
| “伴随应用未连接” | Open `VoicePolishMac`; allow firewall if prompted (loopback only) |
| Mic errors | System Settings → Microphone for VoicePolishMac |
| CodeSign: resource fork / Finder information | Repo is under iCloud `Documents`, so Xcode CodeSign sees `FinderInfo`/`fileprovider` xattrs. **Never** build+sign into `DerivedData/macos` under the repo. Use `./install-macos.command` or `./scripts/install_from_dist.sh` (stages under `/tmp`, strips xattrs, then signs). Mac targets set `CODE_SIGNING_ALLOWED=NO`; install scripts sign. If you already built unsigned products into `dist/macos`, prefer `install_from_dist.sh`. |
| Model not ready | Download in companion, or re-run install to seed `Vendor/Models` |
| Text inserts into wrong app | Expected if focus changes mid-recognition; copy from companion “最近结果” |
| IME not listed / TIS `hits=0` | **这是当前 beta 上常见情况，不必卡在输入法列表。** 自用主路径：`./scripts/fix_macos_selfuse.sh` → 给 VoicePolishMac 开 **麦克风 + 辅助功能** → 菜单栏就绪后按住右 Option。若仍想启用输入法：注销/重启后再看 Text Input + 对话框（简体中文/其他/English）。Computer Use 无法代操作 System Settings。 |
| Ordinary keys broken / cannot switch IME | Run `./scripts/disable_ime.sh --stop-companion` or menu **关闭输入法 / 恢复正常输入**; switch to 双拼/ABC; non-Option keys should passthrough — report if still broken |
| Voice stuck “录音中” | Escape, menu **取消当前录音**, or disable **右 Option 语音监听**; watchdog auto-cancels after max duration |
| Want IME off but keep companion | Menu: turn off **右 Option 语音监听**; do not stay on 粤英语音 input source |

## Tests

```bash
xcodegen generate

# Shared protocol / text processor (iOS host)
xcodebuild -project VoicePolishKeyboard.xcodeproj -scheme VoicePolishApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' test

# Right Option state machine + protocol (macOS)
xcodebuild -project VoicePolishKeyboard.xcodeproj -scheme MacVoicePolishTests \
  -destination 'platform=macOS,arch=arm64' test
```

## Notes / limits

- Free Apple ID: re-sign every ~7 days
- Password fields / secure fields may block third-party input
- After kill/reboot, reopen companion (or rely on login item) to restart mic + bridge
- Keyboard / Input Method do **not** link sherpa-onnx
- No history: audio/text cleared after insert (failed inserts kept in companion for copy)
- macOS v1: Right Option only, no custom shortcut; no Developer ID notarization, Intel, or Mac App Store
