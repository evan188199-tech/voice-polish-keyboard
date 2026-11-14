# #6 翻译模块检查点（2026-11-14）

这是基于 `7e5f86b1c691f2f43a67ec6f44fc3d7f9d8da9ef` 的独立分支 `codex/keyboard-translation`。按本轮检查点范围，完成独立模块、UI 源码和 mock 验证，**尚未完成产品入口/Bridge/ASR 接线，不是已可用的 iOS 翻译发布**。原 #1–#5 分支不动。

## 当前可核验代码

- `Shared/TranslationDraft.swift`：语言与字形分离（English / 简体中文 / 香港繁体）、请求/失败/结果、文本编辑失效状态和长按上滑选择的纯策略。默认成功策略为直接插入一次，预览是可选项。
- `Shared/TranslationRequestExecutor.swift`：取消/超时抢占与迟到结果丢弃；provider 即使忽略取消也不阻塞当前调用者。已被远程服务接受的请求不能被本地撤回，因此不能保证撤销已经产生的服务费用。
- `Shared/TranslationContentGuard.swift`：数字、负号、小数点、ISO 日期、货币、URL、代码 span 和占位符的保守字面检查，包括异常新增。不会用同字符全文比较拒绝正常翻译；不能证明姓名、地名、中文数字、否定和语气的语义正确，仍需核对。
- `Shared/Core/TranslationService.swift`：复用现有 TextPolishing/APITextPolisher；独立翻译提示、空问答历史、chineseScript=nil，避免英语目标被强制中文输出覆盖。默认 allowRequests=false；未提供生产 composition，不能宣称服务/密钥/额度可用。成功需明确目标的非空 JSON 译文，失败不把原文标成译文，不换 provider。
- `Shared/Core/TranslationPreferences.swift`：目标语言增删/排序/去重及同意服务 ID 的本地保存；不是账号认证或能力验证。
- `Keyboard/TranslationViewModel.swift`：可注入服务、语音原文队列、手动文本状态、默认直接交付回调、可选预览、原文恢复、取消/修改/超时/宿主身份变化/重建防过期和防重复。接收 ASR 原文及宿主身份的回调**尚未与现有键盘和主 App 连接**。
- `Keyboard/TranslationSpeakControl.swift`：原创 SwiftUI 单点/长按上滑选择组件及无障碍菜单；未接入现有 Speak。0.35 秒和 45pt 是本项目初始阈值，不是测得 Typeless 时序。
- `Keyboard/TranslationPreviewView.swift`：手动文字/恢复/可选预览组件，编辑、粘贴由集成方提供显式动作，不后台读剪贴板/宿主全文；尚无实际入口。
- `VoicePolishApp/Views/TranslationSettingsView.swift`：目标增删拖动排序与服务说明组件，尚未挂到 SettingsView；不会启用真实后端。
- `Tests/TranslationLinux/main.swift`、`scripts/check_translation.sh`：独立验收入口，不使用 Cursor 的两个路径，不创建第二套长文 formatter。

## 已执行验证

环境为 Debian 13 / 官方 Swift 6.0.3 Linux 工具链。

```
SWIFTC=/path/to/swiftc ./scripts/check_translation.sh
SWIFTC=/path/to/swiftc ./scripts/test_portable.sh
```

- 新模块 66 项断言通过。直接编译真实模型、适配器、ViewModel 和取消执行器；Combine 使用测试接口替身。
- 覆盖单点/长按上滑/无选择/取消/服务不可用，目标持久化，修改原文/目标/宿主身份后旧响应、忽略取消的 provider、超时、对象重建、默认直插回调、可选预览、重复提交/插入、语音分段顺序、原文恢复、数字/代码/URL、无配置、服务同意、能力限制、空/截断/429/网络失败。
- URLSession 只用进程内 URLProtocol 虚构 HTTP，不连接真实 provider；其余是手工文本/受控 continuation mock。预期译文是虚构测试样例，不是翻译质量结论。
- 原 #1–#5 的 110 项便携回归通过。该数字是既有全套断言，不是翻译单项。
- 新 SwiftUI 文件仅通过 frontend 语法解析；没有 iOS SDK 类型检查、构建、模拟器或真机测试。源码/diff 检查通过。

## 下一轮产品集成清单

仍由一个集成负责人串行修改，先复核远端/issue 认领和工作区。Cursor 已公开声明不改 Keyboard/Coordinator/主 App/工程，但接受 #2 两个测试文件的分工提案仍未确认；不能称已达成双方共识。

1. KeyboardView、KeyboardViewModel、KeyboardViewController：把新 Speak 和无障碍入口接入现有录音；手势期间屏蔽横滑切页；长按选目标前不能开始录音。用公开宿主/文档身份跟踪来隔离迟到交付。接手动编辑/明确粘贴/原文恢复，不读取宿主全文。
2. KeyboardBridgeClient、WireMessage、BridgeTransport、KeyboardBridgeServer：最小翻译请求/能力/结果协议，不传密钥；键盘只用主 App 服务。现有 Bridge 不是可信账号共享通道，本模块不扩大权限或传账号数据。
3. VoiceSessionCoordinator：现有主 App 麦克风与 FIFO ASR 提供原文，翻译意图与普通听写/润色/问答分离；目标绑定每个任务。与 OrderedDeliveryCursor 形成唯一交付者，不能让旧管线和新模块两个队列同时插入。当前模块测试只证明其自身顺序，未证明全 App 统一顺序。
4. SettingsView/配置入口及工程 Sources：目标语言管理、已选服务去向和主动同意；未验证的服务/语言禁用并说明。当前未接真实服务，不得将配置字段当成能力验证。
5. Xcode 主 App/扩展完整构建及 iPhone 安装，补真实 ASR→翻译→宿主单次交付、跨模式多段、键盘隐藏/换宿主/切字段、拒权限/Full Access/无网/来电/锁屏/耳机/进程终止与桥接恢复。

本轮未改上述共享入口或工程配置，仅新增独立文件；未改 `Tests/LongFormFidelityLinux/main.swift` / `scripts/check_longform_fidelity.sh`。

## 音频/PiP 静态审查与设备阻塞

搜索未发现 AVPictureInPicture 或可用 PiP 控制器实现。现有 `AudioRecorder.startSession()` 安装音频 tap 并启动 AVAudioEngine，空闲时 `AudioCaptureSink.ingest` 不保存 PCM；**这不能等同于麦克风已经关闭**。普通 App 切换、后台会话、系统录音指示与空闲收音生命周期是下一轮必须整改/验证的明确缺口，当前不勾选通过。

Full Access 只是键盘通信能力，不是麦克风权限。现有录音在主 App，不能让键盘直接取麦克风。未增加 PiP、私有 API、空录音保活、凭证或后台采集。已有 AppSwitcher 私有 API 风险仍在，不宣称 App Store 合规。

没有 Xcode / iOS SDK / Simulator / iPhone，无法交付已经验证可安装的 IPA。Mac 离线不是 Linux mock 能补足的验证。运行时未向本任务暴露可公开核验的精确模型型号或推理档位，不能声称模型升级已生效；按用户要求下一轮使用更强编程模型/high 设置继续。

## 官方交互依据

已阅读 [当前 Translate quickstart](https://www.typeless.com/help/quickstart/translate) 与 [iOS 2.0 多目标语言](https://www.typeless.com/help/release-notes/ios/set-multiple-target-languages)：设置多个目标并排序；长按 Speak 后上滑选择，开始说话；再次点 Speak 结束后译文直接插入。没有每次强制预览确认。

[官方 PiP 说明](https://www.typeless.com/help/release-notes/ios/picture-in-picture) 属于历史 iOS 文档，不证明本项目已有此能力。未播放嵌入视频、未安装参考产品或测量手势阈值；手输翻译是本项目附加入口。

## 保全与写权限

GitHub 写入 403 未解决，本轮不改认证、不扩大权限、不再盲目 push。分支、提交、bundle/补丁只在本地/Library 保全，不是远端可 fetch 的分支。由已有合法写权限的维护者接收 bundle、核验 HEAD 后正常发布独立分支/draft PR；不强推、合并或转移仓库。
