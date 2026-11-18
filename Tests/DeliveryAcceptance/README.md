# 模块 B：交付契约验收

基线：`6343af98d904e7d75eafb009ea82c81c742833b1`。
认领：voice-polish-keyboard #9，评论 `6940656130`。

运行：`bash scripts/check_delivery_acceptance.sh`。只编译四个生产 Swift 文件与本目录入口；不创建应用构建、不访问网络、不触碰设备、麦克风或宿主输入框。脚本生成的二进制及 module cache 位于独立临时目录，结束即删除。

## 实测结果

2026-11-17，MacBook Air 的 Swift 6 编译模式：17 个契约，14 通过、3 失败，退出码 1。红灯是保留的验收缺口，不是预期失败被吞掉；脚本不应被宣称为已通过。

通过项覆盖：取消后拒绝迟到结果、原文保留、新请求隔离旧请求、标记 truncated 的部分输出禁止消费、换请求重试一次消费、恢复原文使旧输出无效、交付许可的取消/会话失效/文档不匹配/一次消费、纠错取消后拒绝建议与确认原文的一次消费。

失败项均在真实 `TranslationDraft` 接口直接复现：
1. `receive(success)` → `consumePreview()` → 相同 `receive(success)` 会重新开放 `consumePreview()`。
2. `receive(success)` → 同请求 `fail(timeout)` 会清除成功输出并覆盖终态。
3. `fail(timeout)` → 同请求迟到 `receive(success)` 会重新开放交付。

这些测试表达单个请求的首个终态应被锁定；重试使用新请求 ID。当前实现只核对请求 ID、原文和目标，未限制已完成请求的后续事件。修复生产状态机属于集成 owner 的写集，本模块未修改。

## 证据边界

这里直接编译并调用生产 `TranslationDraft`、`TranslationDeliveryGuard`、`CorrectionReviewState`，没有复制一个自行实现的“交付管线”作为被测对象，也没有 mock 网络成功来代表真机通过。

这属于生产值类型层的确定性单元契约。没有验证 `KeyboardViewModel` 的实际轮询、`VoicePipeline` 的异步排队、跨进程 ACK、持久化去重、录音、设备或 `UITextDocumentProxy` 的实际插入。上层可能另有事件过滤，所以 3 个红灯不能单独证明用户已遭遇重复插入。重复事件测试模拟“轮询重放到达值类型”条件，并非真实轮询集成测试。

部分输出测试通过现有 `.truncated` 失败字段表达不完整结果；没有声称能识别未标记的不完整文本，也没有创建不存在的流式 chunk 接口。宿主是否接受文字没有回执，本模块只验证插入许可/可消费输出，不声称实际插入成功。

## 集成复核

集成负责人在独立副本重现上述 14 过 / 3 失败后，为 `receive` 和 `fail` 增加正在执行门禁，并拒绝空失败请求 ID。首个终态锁定后，重放不再开放预览，迟到的成功或失败均不覆盖终态。复测 17/17 通过，原 `check_translation.sh` 逻辑/mock 回归通过。未进行 Xcode 或真机宿主验证；未修改用户历史。
