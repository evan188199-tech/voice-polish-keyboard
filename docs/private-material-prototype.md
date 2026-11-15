# 私人词汇与素材安全原型（#5）

本轮仅有可运行的本地/演示模型与 UI，**生产账号未连接**。没有 OAuth 应用、生产凭证、真实中台同步、客户发送、真实素材或新收费服务。

## 三层与原型入口

主 App 的“私人素材安全原型”提供两个明确标注的演示工作区。公共地名词典与此模块独立；私人词汇与素材不写入公共词典、模型词汇提示或测试样本。

用户可明确选择一个本地 JSON 文件，格式为 `{"terms":[{"term":"桂林","kind":"place"}]}`；kind 支持 place/general/privateRoute。只取这两个白名单字段，其他字段不回显、不保存。含数字/链接/敏感标签等候选保守拒绝，但这不是可靠的自动脱敏：仍需逐项选择并确认。确认选中的词条保存于主应用本地目录，排除系统备份，并在 iOS 上使用文件保护；同一演示账号重新打开可恢复，切换账号、注销或撤权时删除。存储失败会提示，不宣称云端同步。

若删除失败，界面会提示本地文件可能尚未删除并要求重试，同一会话在删除成功前不能重新打开账号。该重试标记只存在内存中；如果操作系统持续阻止删除并且应用退出，不能保证文件已清除，须重新尝试注销并确认成功。

素材与词汇分离，模型包含名称、批准摘要、客户链接、图片批准状态、归属、核实/对外状态、渠道、到期时间和版本。每次草稿、分享、复制均检查当前账号、已核实、批准对外、正确渠道、有效期、版本、归属与本次确认。文字另需已核实客户访问权限和安全 HTTPS 目的地。仅页面可读不能使客户链接自动合格。

全部演示数据人工虚构，示例 URL 使用保留的 `.test` 域名且不打开网络；示例图是本项目用 UIKit 绘制的固定大小占位图，不能当真实产品图使用。

## 操作与降级

- 文字/链接生成可编辑草稿，标明未发送，可清除；不自动写入其他应用。
- 图片由主 App 系统分享；最终用户自行选择目的地/收件人。明确点击并确认后也可复制到本机剪贴板，localOnly=true，60 秒过期；提醒用户自行粘贴并确认。退出/换工作区时仅清理由本页创建且未被别人覆盖的剪贴板项，不读取剪贴板正文。
- 没有把图片当 insertText 注入附件，没有模拟宿主发送按钮，没有显示“已发送”。宿主拒绝图片/第三方键盘等行为未在真机验证。
- 无账号/服务、无 Full Access、没有安全共享容器时，私人素材进入键盘的快照接口一律返回不可用；语音和本地地名词典继续使用各自路径。

## 现有 Bridge 静态审计与阻塞

检查了 `BuildToken.swift`、`BridgeTransport.swift` 及两个 entitlements：当前没有 App Group 权益；token 由源码常量派生，不是账号级凭证；TCP 没有 TLS/客户端身份认证。监听已限制为 loopback，但仍不能把现有 Bridge 当作安全私人素材共享通道。

因此本轮不扩充 Bridge 命令来传账号、私人索引、素材或长期 token，也不修改签名安全配置。未来需要支持的主 App 授权流程、Keychain/安全服务、只读最小权限、账号级短期授权、经过验证的传输或 App Group 权益、撤权和缓存清除，再启用最小只读快照。生产适配器目前只有协议边界，没有伪造登录成功。

快照值类型包含账号、版本、到期与最小草稿项目；测试其账号/版本/过期校验，但生产快照生成仍关闭。真实客户 ACL、素材公开资格和真实分享均需单独授权与核验。

## 验证与未测项

`./scripts/test_portable.sh` 运行真实权限门控、白名单提取、工作区/缓存和 mock 适配器。覆盖待定/内部/未核实/过期/渠道、客户访问、内部/含凭证/不安全 URL、逐项确认、跨账号旧预览、注销撤权、快照失效与无安全传输降级。iOS 模拟器测试另验证已选词条的持久化、排除备份、关闭页面后恢复和注销删除。全部为虚构 fixtures，未使用私人文档、URL、凭证或素材；没有网络请求。

模拟器测试未覆盖完整 SwiftUI/UIKit 交互：JSON 文件选择器、系统分享面板、localOnly/过期剪贴板、宿主粘贴、安全文本框和扩展内存均待进一步验证，真机行为也未验证。本轮示例图固定 640×400，不从外部加载超大图。

Apple 官方依据（2026-11-14 阅读）：
- [Custom Keyboard 指南](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)：键盘切换、textDocumentProxy、Full Access、宿主限制。
- [Configuring open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)
- [Configuring a custom keyboard interface](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)
- [UIPasteboard setItemProviders](https://developer.apple.com/documentation/uikit/uipasteboard/setitemproviders(_:localonly:expirationdate:))：localOnly 与 expirationDate。
