# 从「托盘持有 dsh」迁移到「systemd 持有 dsh」

## 为什么要迁移

旧架构里，托盘用一个前台 `wsl.exe` 持有 `dsh web`，托盘退出/崩溃/注销 = 服务死亡。
这在 WSL2 下是成立的权宜之计（实测：`wsl.exe` 客户端退出后，其会话内进程 1 秒内被
回收，`setsid`/`nohup` 都救不回来），但它有两个代价：

1. 托盘成了单点故障：WPF 里一个未捕获异常就会连带杀掉服务，进行中的会话直接丢失。
2. 托盘必须一直活着：重启托盘、注销、换用户都要重来一遍。

systemd 负责进程管理与自愈（`Restart=on-failure`），但它**不能**让发行版活下来：WSL2 在最后
一个 `wsl.exe` 客户端退出约 10–30 秒后回收发行版，systemd 与所有 unit 一起消失；
`loginctl enable-linger` 只让 user manager 在 VM 存活期间不被回收，救不了 VM 本身。

所以托盘另外常驻一个 `wsl.exe … -- /bin/sleep infinity` 客户端（keeper）钉住 VM。它与
dsh 没有父子关系，只负责"占位"：托盘重启会复用它，托盘退出时按 `stopOnExit` 决定释放还是
留下（默认释放，见下表）。这一步是上线后根据实际故障补上的（见
[`改进方案`](../dsh-wsl-tray-改进方案.md) 第 15 节）。

## 迁移前检查

```bash
ps -p 1 -o comm=                    # 必须是 systemd
systemctl --user is-system-running  # running / degraded 都可以
pgrep -af 'dsh web'                 # 记下当前实例，迁移会结束它
```

当前打开的 agent 会话会随迁移中断（dsh 进程被替换）。请在**没有长任务在跑**时执行。

## 步骤

在 Windows 侧、仓库根目录：

```powershell
pwsh -ExecutionPolicy Bypass -File tools\switch.ps1 -DryRun   # 先看它会做什么
pwsh -ExecutionPolicy Bypass -File tools\switch.ps1           # 备份 → 安装 → 停旧实例 → 启 unit → 重开托盘
```

> 仓库如果放在 `\\wsl.localhost\...` 上，默认的 `RemoteSigned` 会拦下未签名脚本
> （报 `SecurityError: ... 未数字签名`），所以必须带 `-ExecutionPolicy Bypass`；
> 仓库拷到本机磁盘后可以省略。

`switch.ps1` 依次做：

1. 把现有 `%LOCALAPPDATA%\dsh` 下的脚本/文案/配置和 `~/bin/dsh-*.sh` 备份到
   `%LOCALAPPDATA%\dsh\backup\<时间戳>\`；
2. 调 `tools/install.ps1`（复制托盘文件、WSL 脚本、unit，`enable-linger`，unit 保持 `disable`）；
3. 结束旧托盘进程；
4. 按**端口**（不是 `pkill -f 'dsh web'`）结束旧实例，避免误杀其它 profile；
5. `systemctl --user start dsh-web`，等端口就绪；
6. 重新拉起托盘。

## 迁移后验收

```powershell
pwsh -ExecutionPolicy Bypass -File tools\verify-tray.ps1      # 应输出 result=PASS
```

```bash
systemctl --user status dsh-web        # active (running)
journalctl --user -u dsh-web -n 20     # 无报错
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3080/   # 401
```

手工确认三件事：

1. 右键面板「停止服务」→「确认停止」后，图标消失、浏览器刷新变「无法访问」——
   这是设计语义：托盘图标就是应用开关（`stopOnExit` 可关掉这个行为）。
2. 再双击快捷方式，托盘回来、服务重新起来、标签页自动打开。
3. `systemctl --user restart dsh-web` 之后，左键托盘能用新 token 打开界面（旧标签会 401）。

## 回滚

```powershell
pwsh -ExecutionPolicy Bypass -File tools\rollback.ps1                # 用最新的备份
pwsh -ExecutionPolicy Bypass -File tools\rollback.ps1 -Backup <dir>  # 指定备份
```

回滚会停掉并 `disable` unit、恢复备份的 Windows/WSL 脚本、重开旧托盘；旧托盘会像
以前一样自己持有 `dsh` 进程。unit 文件保留在 `~/.config/systemd/user/`（已 disable），
下次再迁移会很快。

## 已知差异

| 项 | 旧架构 | 新架构 |
|---|---|---|
| 服务归属 | 托盘（前台 wsl.exe） | systemd 用户单元 |
| 托盘退出 | 服务停止 | 服务停止，图标消失即应用关闭（`stopOnExit=false` 可保留服务） |
| 托盘崩溃 | 服务停止 | 服务在 10–30 秒后随 VM 停止（keeper 在 kill-on-close Job 里；`stopOnExit=false` 时它不在 Job 内，服务继续） |
| dsh 崩溃 | 面板变灰，不自动拉起 | `Restart=on-failure` 3 秒后自动重启 |
| Windows 注销 | 服务停止 | 服务停止（keeper 随会话结束） |
| 发行版存活 | 托盘的前台 `wsl.exe`（同时持有 dsh） | keeper 常驻客户端（只占位，不持有 dsh） |
| 停止方式 | `pkill -f 'dsh web'`（会误伤） | `systemctl --user stop`（精确） |
| 日志 | 每次启动截断 | 追加，托盘只读尾部，靠 `[boot]` 标记判新旧 |
| 端口 | 脚本里 6 处硬编码 | 配置文件一处 + `dsh-serve.sh` |
| 开机自启 | 无（手动双击） | 仍为手动双击；unit 为 `disable`，只有托盘能启动服务 |
