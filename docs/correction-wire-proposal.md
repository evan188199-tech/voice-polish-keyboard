# 纠错逐任务桥契约：接收侧适配状态

本文件根据 Mac 负责人提供的**已实现但尚未导出至本分支**的协议描述更新；云端当前 `BridgeResponse` 类型仍不含这些字段，不能声称跨端编译或集成完成。

- 成功普通听写的 `.text` 结果使用非空 `jobID`，同一响应携带可选 `rawTranscript: String?` 与 `correctionReviewRequired: Bool?`。原文是纠错前、已经按当前字形设置处理的转写。等待、失败和翻译不携带这些元数据，不应以其缺失推断它们出错。
- `correctionReviewRequired == true` 必须同时有非空 `rawTranscript` 和 `jobID`，送入对应任务的确认界面，原文只用于本地确认和恢复，不写日志。`false` 可走原普通听写流程；如果可见原文或结果仍明显包含纠错指令，按不一致保守隔离。
- 旧消息缺 flag、缺 job ID、flag 为 true 但原文缺失或空白、字段类型无效、空结果，均为未知；不能当作无需确认。当前云端旧类型会丢弃未知字段，故在接入 Mac 真实 Codable 类型前，所有普通听写结果都会被保守隔离并要求明确处理；这是有意的兼容降级。
- 对明确关联的翻译任务先走翻译业务，不要求此元数据；失败、等待也不触发文字交付。保护后续段落顺序，拒绝旧任务、旧界面回调与重复确认。明确操作“插入当前输入框”不证明仍是最初字段；自动交付仍需原目标验证。

`CorrectionWireDisposition` 暂通过编码当前 `BridgeResponse` 后解码这两个可选字段接收；编码只在内存执行，不输出文本。由于当前类型没有这些字段，默认必然返回未知。拿到 Mac 的准确协议源码并逐行合并后，应改用实际类型的直接访问并在 Xcode 及真实宿主验证。`check_correction_wire_contract.sh` 仅测试合成 JSON 的接收判定；`check_correction_delivery_contract.sh` 检查当前真实 DTO 缺字段并保持红色。
