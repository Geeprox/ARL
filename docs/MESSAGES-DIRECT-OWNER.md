# ARL 直接连接信息：邮箱文字候选

本批将正式 pane 接入 MessagesDirectView/Controller，与 Notes 共用同一 AppleDirectExecutor 和固定 ARL 主应用 Apple Events 权限身份。不新增 helper/Python/imsg/osascript、Contacts、聊天库、外部RPC或持久授权。旧V2源码保留，不给旧admission赋值。安装仍49，本批源码未native验收。

仅显式页面操作：权限检查不弹窗，尚未申请时由用户点击允许；检查最多8个账户，只保留原生枚举sims/enabled/conn。用户选账户并输入单个确切ASCII邮箱（≤254字节），只在该账户内查询hndl匹配的participant ID投影，返回必须严格list且唯一；不包装scalar、猜ID、扫全收件人或姓名。按实际ID重建后核ID/精确handle/账户归属，发送前再次核验。筛选编码依据本机Messages.sdef及AEObjects.h；目标实际支持/返回编码仍未验。

用户核对页面账户、收件人、完整文字，点击一次发送。参数仅icht/send、全文和绑定participant，≤8192字节。共享队列内20秒总预算，每事件≤5秒；page epoch、可见前台、锁屏/会话、取消、目标进程代次与签名、期限保留。描述符不跨队列。

独立messages-direct-once-v1目录/anchor，0700/0600、no-follow链、同uid、nlink1、互斥、O_EXCL与fsync。只存UUID/digest/consumed_unknown及accepted_by_messages；先持久占用再发送，部分写/超时/错误一律不重放。已接受仅表示系统接受请求，未核实际通道/送达，不用null返回推断失败或重发。未知记录阻断后续发送，不能自动删记录、修anchor或换ID绕过。与Notes独立日志，保留原字节。

公开API没有禁SMS fallback开关。邮箱及sims约束ARL选择，但不证明Messages内部通道；电话、群、附件、历史/锁屏后台/Mio暂未开放。实际邮箱注册/接收方/送达未知。真实发送必须由用户明确核对确切收件人和全文后操作，合成fixture不提供真实发送权限。仅源码开发/合成测试，不主动请求权限、读取账户或发消息。
