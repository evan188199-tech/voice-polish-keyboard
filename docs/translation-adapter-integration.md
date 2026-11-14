# 可配置翻译适配：隔离集成说明

当前主应用桥仍使用 `DisabledTranslationService`，不会调用本实现。Mac 负责人确认文件所有权、权限与产品设置后才能另行接线；本轮没有修改桥、读取真实密钥或调用服务。

仓库已有 `ConfiguredTranslationService` 负责翻译指令、响应 envelope、目标语言与受保护数字检查；本次复用该逻辑，补充 `TranslationServiceFactory`、专用 `StrictTranslationPolisher` 和可取消的 `ManagedTranslationService`。传输仅接受显式批准的 HTTPS endpoint、模型、目标集合及服务 ID，拒绝 URL 内用户名密码；系统和用户消息分开，不做将二者合并的兼容重试。地址仅表示 OpenAI Chat Completions 格式；VPS/其他服务是否兼容必须独立验证，不能据此假设兼容。

接线建议：主应用按用户实际配置创建 `PolishingSettings`，取得用户对**服务 ID、规范化 endpoint、模型、目标集合**完全一致的 `TranslationServiceApproval`，并在用户主动启用、网络发送授权成立后调用 `TranslationServiceFactory.make(configuration:)`。工厂缺授权／配置时返回不可用服务，不发送请求。由主应用为当前配置持有同一个服务实例，并将其注入 `TranslationBridgeHandler`；不能为每条消息新建实例，否则取消和请求 ID 去重失效。服务配置变化／撤权时应由桥负责人调用 `ManagedTranslationService.revoke()`、隔离在途请求并重新获取批准后创建新实例；需要持有该 actor 而不是只保留不可撤权的临时对象。

`ManagedTranslationService` 本实例内拒绝重复请求 ID，最多记录 2048 个，达到上限后停止接新请求；进程重建不提供持久幂等。取消／超时让本地调用结束并丢弃迟到返回，无法撤回已被远端接收的请求。真实 `URLSession` 禁止重定向、使用临时会话；1 MiB 检查在接收之后进行，不是流式内存上限。原文完整回显被拒绝，但确实存在与原文完全相同的合理译文，会因此保守拒绝。简单字段/数字检查无法验证语义、隐私或提示注入安全，必须人工验收；系统消息和用户数据分离也不能保证模型一定遵守指令。

独立虚构传输只在本机返回预设数据，不进行 DNS 或 HTTP；测试通过不证明真实供应商兼容、iOS URLSession 行为或翻译质量。真实启用前需另行确认目标服务、授权和费用，并完成设备/宿主、取消/超时、网络、语义、声学和隐私验收。不要记录凭据或用户原文。
