# ARL Codex 服务 v2

五档配置与 NAS 两个既有消费范围的 v2 服务已上线。ARL 原生偏好设置支持每档独立配置模型／思考强度；PDF 翻译和 BiliNote 均通过显式选型、只指定套餐两种真实任务验收。本地累计调用上限为 null，沿用现有 Codex 账户。

- [协议设计](PROTOCOL.md)、[返回值与错误](WIRE-EXAMPLES.md)与 JSON Schema。
- [本次实现源码](../../../integrations/nas_codex_v2_20261024/README.md)：固定基线、运行边界与验证说明。

16 项 v2 检查＋13 项 v1 回归通过。四项应用任务为真实推理；自动执行类回归使用合成 provider。实际私有运行回执及测试产物保存在所属任务工作区。
