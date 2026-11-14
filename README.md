# 粤英语音键盘 (Voice Polish Keyboard)

专为 **iOS 18+** 打造的个人离线/云端润色语音输入法：

- **点击说话**：默认语音页，点击开始、再次点击完成；显式取消本段，左右滑动切换文字键盘。
- **端侧离线识别**：集成 sherpa-onnx + SenseVoiceSmall INT8（支持 中 / 英 / 粤 / 日 / 韩 混合识别）。
- **保真排版**：明确枚举转列表，长文保守分段，保留识别原文供恢复；云端失败回退完整本地结果（[规则与验证](docs/local-text-processing.md)）。
- **本地输入风格**：内置只纠错、代码、自然润色和结构化提示词；可创建仅存本机的自定义整理风格。
- **繁简输出转换**：支持简体中文、香港繁体等输出字体无缝转换。
- **多段异步并行**：点击完成立即提交，无需等待识别完成即可连续录制下一段，系统自动按说话顺序依次插入。
- **主 App 与键盘分离架构**：主 App 统一管理麦克风、SenseVoice 模型与云端 API，通过环回 TCP Bridge (`127.0.0.1:52741-52743`) 为键盘扩展提供响应，免 App Group，支持个人免费 Team 签名。

## 项目架构

| 组件 | 作用 |
|-----------|------|
| `VoicePolishApp` | iOS 主应用，负责麦克风录音、SenseVoice 离线识别、云端润色 API、Bridge 服务 |
| `Keyboard` | iOS 键盘扩展，负责点击录音 UI、模式/繁简菜单、横滑换页与文本插入 |
| `Shared` | 通讯协议、数据快照、ASR/润色核心管道、繁简转换器 |
| `Vendor/SherpaOnnxPackage` | 本地 SPM 包，封装 sherpa-onnx 与 onnxruntime xcframeworks |

## 多段异步处理管道

- 点击完成后**立即入队提交**，无需等待上一段识别或润色完成，可随时点击开始下一段录制。
- 本地 SenseVoice 识别按 **FIFO 严格串行（并发 1）**；云端 LLM 润色最多 **并发 2**。
- 云端响应时间即使颠倒，最终文本也会**严格按说话顺序交付插入**。
- 显式取消仅丢弃当前正在录制的段落，已提交的任务保留并依次处理。
- 每段结果会保存到本机语音历史；键盘保留最近结果，可在宿主文本框拒绝插入时重新插入或复制。

## 4 种润色模式

| 模式 | 键盘短标签 | 说明 |
|------|-------|----------|
| 只纠错 | 纠错 | 仅修正 ASR 错别字与标点符号，保留原始口语风格，不回答问题 |
| Coding | 代码 | 整理编程口语意图，保留标识符、路径与代码 Token |
| 润色词句 (默认) | 润色 | 口头语整理、标点规范、语序微调 |
| 问 LLM | 问答 | 将语音识别结果作为问题或指令执行，仅输出最终结果（如“请用英语输出『你多久回来一次』” → 输出 `How often do you come back?`）。若云端失败，自动回退到本地识别原文 |

点击顶部模式菜单选择；再次选择当前模式可关闭润色。语音就绪和处理队列分开显示；更多菜单可重新插入/复制最近结果。

本轮实现范围、状态表与未验证项见 [语音键盘验收记录](docs/voice-keyboard.md)。

## iOS 构建与安装

### 环境要求

- Xcode 16+ (或 Xcode-beta) 及 iOS 18+ SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Apple Developer 个人 Team ID（在 `project.yml` 中配置）

### 编译与部署到设备

```bash
cd voice-polish-keyboard

# 1. 生成项目并编译安装到连接的 iPhone
./scripts/install_device.sh

# 2. 解锁 iPhone 后，启动主应用
xcrun devicectl device process launch --device <device-id> com.voicepolish.app
```

可选：从 Mac 本地预置模型文件到手机：

```bash
./scripts/seed_model_to_device.sh
```

### 首次使用检查清单

1. 解锁手机并打开 **粤英语音键盘** 主应用。
2. 在主应用中下载或加载 SenseVoice 模型（~230 MB）。
3. 允许麦克风权限，点击 **启动语音会话**。
4. 手机 **设置 > 通用 > 键盘 > 键盘**，添加 **粤英语音键盘** 并开启 **允许完全访问**。
5. （可选）在主应用设置中填入 OpenAI 兼容 API Key，并选择所需的润色模式。

## 常见问题 (FAQ)

### 连续多段语音怎么处理？

所有已提交段落均会保留。本地识别按录音顺序串行处理，云端润色即使先后返回顺序不同，最终文本仍按说话顺序交付。

若需要彻底重置会话（麦克风、桥接与后台状态）：

1. 打开主应用
2. 点击 **停止语音会话**，再点击 **启动语音会话**

> 注意：主界面的“清除”按钮仅用于清空展示视图中的最近识别/润色结果文本。

## 单元测试

```bash
xcodegen generate

# 运行 iOS 单元测试
xcodebuild -project VoicePolishKeyboard.xcodeproj -scheme VoicePolishApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Linux 逻辑检查（需 Swift 6；不代表 iOS 构建/真机通过）：

```bash
./scripts/test_portable.sh
```

## 本轮独立增量与验证边界

- [语音优先界面与交互（#1）](docs/voice-keyboard.md)
- [长段保真整理与口述纠字（#2、#3）](docs/local-text-processing.md)
- [本地地名词典与候选确认（#4）](docs/place-dictionary.md)
- [私人词汇/素材安全原型（#5，生产账号未连接）](docs/private-material-prototype.md)

以上有 Swift 6 便携逻辑与 mock 检查；不等于已通过 Xcode、真实 ASR、iPhone UI 或宿主分享/粘贴验证。已有私有 API、模型许可和仓库许可问题仍待处理，不宣称 App Store 合规。
