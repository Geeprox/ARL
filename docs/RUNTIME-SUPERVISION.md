# 运行时守护与异常恢复

ARL 的守护分两层。当前用户 LaunchAgent 负责 ARL 主进程，ARL 原生 owner 负责包内 Core 与 Mio 子进程。子进程监测不依赖窗口是否显示或界面状态刷新。

## 主进程

受管安装使用 `RunAtLoad=true`、`KeepAlive.SuccessfulExit=false`、`ThrottleInterval=10`、`ExitTimeOut=45`。非正常退出由 launchd 重新启动，正常退出保持停止；已卸载或停用的任务不会被 owner 重新登记。升级计划保留原 Label、程序路径和其他启动配置，同时补齐上述守护字段，不修改账号或业务授权。

双击启动同样需要进入此 LaunchAgent，而不是让另一个 GUI 进程持有运行时。正式安装路径的前台启动器在创建 SwiftUI、凭据 owner 或 socket 之前，校验本用户已有 agent 的固定 Label、执行路径、参数和守护配置，写入仅供显示窗口的 15 秒短期请求，唤起同一个受管任务后结束。受管实例消费该请求并显示窗口。正常退出保持停止，下次打开再次交接；开发/隔离运行不接管正式任务。诊断页直接核对 launchd 当前 PID 与本进程，以及子进程监测是否运行，不以 plist 存在代替实际受管状态。

## 子进程

原生 owner 同时监听精确 Process 的退出回调，并每秒核对受管子进程。没有主动退出、停用或安装维护标记时，异常退出（包括长驻服务意外返回 0）会触发自动恢复。首次等待 1 秒，连续失败依次等待 2、4、8、16、32 秒，之后每次最多等待 60 秒；进程连续存活 60 秒后复位退避。

自动恢复只回收已经退出的精确子进程。健康的兄弟进程继续运行。每次尝试重新检查现有 activation、Core manifest、应用签名、Mio policy 和固定包内执行路径；不创建新凭据、扩展范围或替换授权。旧进程回调同时校验 generation 和 Process 对象，不能影响替代进程。自动恢复与手动恢复、正常退出共用 owner 的串行生命周期门；不确认旧进程结束时不会创建同一 child 的重复实例。

正常退出取消监测，取消退出后恢复监测；手动停止保持停止。`disabled` 和 `install-maintenance.json` 存在期间不自动拉起。既有任务存储继续区分幂等读与结果不明的外部操作；恢复服务不构成重新提交写入或模型请求的授权。有限事件、退出码、重试间隔和新 PID 使用现有轮转连接日志记录，不记录业务正文。

## 本机登录连接

原生登录服务持有跨进程独占锁直到监听结束。异常退出后，仅在获得同一私有端点的独占锁、探测明确返回 `ECONNREFUSED`，并再次核对 socket 的 UID、模式、设备与 inode 未变化时，清理这个已失效的端点。活动监听者、未知文件、锁冲突和无法确认的探测结果均保留。

后台维护循环在旧 worker、请求及监听端点均确认结束后，按 5、15、60、120、300 秒退避重建连接；稳定运行 30 秒后复位。身份核验失败或清理未确认时保留人工恢复入口。连接恢复只重建服务，不重放业务调用。界面显示实际失败阶段，成功后清除旧失败提示。

## 验证与交付边界

2026-11-03，实际 Swift owner 在临时目录与隔离子进程上验证了 SIGKILL 恢复、健康兄弟 PID 不变、旧回调隔离、维护/停用/退出暂停、取消退出、启动失败退避、连续存活复位、意外返回 0 和手动停止。相关运行时、Codex 恢复、安装计划与测试分组回归共 81 项通过，完整原生源码编译通过。

另用唯一临时 LaunchAgent 实测了与正式配置相同的 10 秒节流：SIGKILL 后出现新的进程，正常返回 0 后没有再次启动；测试任务已卸载，正式 ARL 与其他服务未被终止。该实测证明隔离 launchd 机制，不代替正式应用升级后的崩溃验收。

源码与 CI 验证入口：

```sh
python3 -B script/check.py --profile native --module tests.test_bundled_runtime_watchdog --output build/check-watchdog
python3 -B script/check.py --profile portable --module tests.test_install_unified_update --output build/check-supervision-upgrade
python3 -B script/check_native_source.py
```

维护机已完成 0.1.2 build 146 的签名构建与受管升级，计划保留原 authority/Mio/存储范围，安装收据为 committed/applied。升级后检查队列空闲与精确父子进程身份，再对正式 Core 执行一次 SIGKILL：2.864 秒后新 Core 就绪，旧 Core 已退出，主进程和健康 Mio 的原 PID/出生代次保持不变。验收脚本未发模型或 NAS 业务请求，NAS 读取范围未改变。真实 Mio 强杀未另行执行；主进程的异常重启采用上面的隔离 LaunchAgent 实测。

本机收据位于 ignored `build/watchdog-installed-146-acceptance.json`、`build/watchdog-install-146-result.json` 和 `build/releases.noindex/ARL-0.1.2-146/artifact.json`，不随公开源码发布。其他安装需升级至包含该实现的构建后生效。进程挂起、机器断电、睡眠和长时间运行的可用性分别需要其他证据；退出恢复检查不能证明这些情况已通过。

2026-11-04 的正式 156 验收补齐了主进程故障注入：Core 异常退出后约 3.7 秒恢复，健康兄弟进程保持不变；ARL 主进程异常退出后约 2.0 秒由 launchd 重新启动，核对了新 PID 和就绪状态。157 另行验证正常退出保持停止，从访达首次重新打开后交回系统守护并显示前台窗口。窗口请求只在窗口创建后消费，不携带业务操作。以上结果均为单次受控空闲测试，不代表长期可用率。
