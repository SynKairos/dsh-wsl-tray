# dsh-wsl-tray

A Windows tray shell for **DeepSeek Harness (dsh)** running inside WSL2: it is the switch
for the whole application — start it, watch it, open it, and stop everything when you quit.

The service itself belongs to **systemd** (a user unit), not to the tray: `Restart=on-failure`
brings dsh back after a crash, and the unit outlives any terminal. The tray is the controller —
the only thing that starts or stops it — and **closing the tray icon means the app is closed**:
the unit is stopped, the keeper is released and the VM goes back to `Stopped`.

> 个人项目，与 DeepSeek 官方无关。只在一台机器（Windows 11 + WSL2 Ubuntu-24.04 +
> systemd 255 + dsh 0.2.2-rc.5）上验证过，不保证通用。

---

## 工作方式

```
桌面快捷方式
  └─ wscript.exe  %LOCALAPPDATA%\dsh\dsh-tray.vbs          （无黑框）
      └─ pwsh 7（回退 powershell 5.1）-Sta -NoProfile -File dsh-tray.ps1
          ├─ NotifyIcon（托盘图标）
          ├─ 自绘 WPF 无边框面板（300 DIP，锚定在点击位置）
          ├─ systemctl --user start|stop dsh-web           （经 wsl.exe，一次性进程）
          ├─ keeper：wsl.exe -d <distro> -- /bin/sleep infinity（钉住 VM，见下）
          └─ 读日志尾部取 token → 打开/聚焦浏览器标签

systemd（PID 1）── dsh-web.service ── bash -l ~/bin/dsh-serve.sh ── dsh web --no-open
                     127.0.0.1:3080，Restart=on-failure，日志 append 到
                     ~/.local/state/dsh-web.log
```

**为什么还需要一个 keeper**：WSL2 在最后一个 `wsl.exe` 客户端退出约 10–30 秒后回收整个
发行版，systemd 和所有 unit 一起消失；`loginctl enable-linger` 只保证 user manager 在
VM 还活着的期间不被回收，救不了 VM 本身。所以托盘额外常驻一个
`wsl.exe … -- /bin/sleep infinity`（keeper）把 VM 钉住：它与 dsh 不是父子关系，托盘重启
不会打断服务（重启时复用已有的 keeper）。

keeper 被放进一个 `KILL_ON_JOB_CLOSE` 的 Job Object：**托盘无论怎么消失**（正常退出、
崩溃、被 `taskkill`、注销），操作系统都会立刻回收它，不会留下一个持着 VM 的孤儿。
代价是崩溃也会中断服务——这正是"图标即应用"的语义；要"托盘随便退、服务照跑"，把
`config.stopOnExit` 设为 `false` 并接受 keeper 常驻。

**为什么不让托盘持有 dsh**（旧方案）：那时 `wsl.exe` 是 dsh 的父进程，托盘一死服务就死。
现在 dsh 的父进程是 systemd，`Restart=on-failure` 还能自愈；keeper 只负责"占位"，不参与
服务的生命周期。详见 [`MIGRATION.md`](MIGRATION.md)。

| 交互 | 行为 |
|---|---|
| 左键托盘图标 | 已有 dsh 浏览器标签就聚焦它；否则用带 token 的 URL 开新标签（800 ms 去抖） |
| 右键托盘图标 | 弹出面板（打开界面 / 重启服务 / 停止服务 /（失败态）打开日志） |
| 再双击一次快捷方式 | 聚焦已打开的那张标签页，而不是弹面板 |
| 冷启动（服务未运行） | 面板自动弹出「启动中」，就绪后打开标签页并自动收起 |
| 停止服务（默认） | 面板内联确认 → 停 unit → 释放 keeper → **退出托盘** |
| 停止服务（`stopOnExit=false`） | 面板内联确认 → 停 unit，托盘保留 |
| 退出托盘（`stopOnExit=false`） | 只关托盘；服务在跑就保留 keeper，服务没跑则顺手释放 |
| 重启服务 | 面板内联确认 → 停止 → 启动，托盘不退出 |
| 状态点 | 每 3 秒判定：绿=运行 琥珀=启动中/停止中 灰=停止 红=失败（附原因行） |

启动、停止、重启都是**异步状态机**：点击只负责 spawn，轮询由 400 ms 的
`DispatcherTimer` 驱动，UI 线程不阻塞。停止会等到端口真正释放才算成功，否则报
「停止失败」，不会被下一轮探测悄悄抹平。

确认框不用 `MessageBox`：Win32 对话框无法适配暗色面板。红色「确认停止」= 结束应用，
琥珀色「确认重启」= 只中断服务。`stopConfirm=false` 可关掉这一步。

## 退出契约

默认（`stopOnExit=true`）下托盘图标就是应用。**图标消失意味着**：单元已 `stop`、keeper
已释放、端口已释放、发行版回到 `Stopped`。实现必须按这个顺序：

1. 置 `Exiting` 标志并停掉所有 `DispatcherTimer` —— 3 秒轮询里的 keeper 重建逻辑会把刚
   杀掉的 keeper 又拉起来；
2. `systemctl --user stop`，然后**等端口真的释放**（超时才对 cgroup 发 SIGKILL）；
3. `finally` 里强制释放 keeper（不判断服务是否还在跑，此刻它必须走）；
4. 先 `Application.Shutdown()`，再 `Dispose` 图标与面板 —— 反过来的话，中途一个异常就会
   留下一个没有图标、没有窗口、只能从任务管理器杀掉的进程。

附带结果：**`wsl --shutdown`、注销、重启都不会留下僵尸**。

`config.stopOnExit=false` 是唯一例外：面板底部的「停止服务」变成"停服务但留在托盘"，并
多出一行「退出托盘」；退出时如果服务仍在跑，keeper 会被保留（它此时**不**进
kill-on-close Job，所以托盘崩溃也不会被回收），服务继续活着，下次启动托盘时复用同一个
keeper。如果退出时端口已经没在监听，keeper 仍会被释放，免得白占着 VM。

单元是 `disabled` 的：任何一次 `wsl.exe` 启动发行版都不会自动拉起 dsh，只有托盘能启动它。
`loginctl enable-linger` 保持开启（让 user manager 随 VM 起来，托盘启动更快），它本身不产生残留。

## 目录

| 路径 | 内容 |
|---|---|
| `tray/dsh-tray.ps1` | 托盘主程序（纯 ASCII，中文文案全部外置） |
| `tray/dsh-tray.vbs` | 免控制台启动器，路径全部取自环境变量 |
| `tray/dsh-labels.json` | 中文文案（UTF-8） |
| `tray/dsh-tray.config.json` | 唯一配置源：端口 / 发行版 / 账号 / unit / 日志路径 / 开关 |
| `tray/dsh-icon.ico` | 7 档多尺寸图标（深色圆角底板 + 浅色标记，按尺寸分别构图） |
| `systemd/dsh-web.service` | 用户级 unit（Type=simple，Restart=on-failure，**disabled**） |
| `wsl/dsh-serve.sh` | systemd 前台入口：清理代理变量后 `exec dsh web` |
| `wsl/dsh-run.sh` | 手动 CLI：启动 unit 并开浏览器（托盘不再使用） |
| `wsl/dsh-stop.sh` | `systemctl --user stop` + 等端口释放（不再 `pkill -f`） |
| `wsl/dsh-log.sh` | 面板「打开日志」的 WSL 回退路径 |
| `tools/install.ps1` | 幂等安装：文件 + unit + linger + 快捷方式 + 部署记录 + 自检 |
| `tools/switch.ps1` | 从旧架构（托盘持有进程）一次性切换，含备份 |
| `tools/rollback.ps1` | 回滚到切换前的文件与旧托盘 |
| `tools/verify-tray.ps1` | 不需要 GUI 的全链路静态校验（`-Root` 可校验任意副本） |
| `tools/deploy-shortcut.ps1` | 重建桌面快捷方式 |
| `assets/panel.png` | 面板离屏渲染 |

## 安装

前提：WSL2 已启用 systemd（`/etc/wsl.conf` 里 `[boot] systemd=true`，`ps -p 1` 显示
`systemd`），WSL 里已装好 dsh，Windows 侧有 PowerShell 7 或自带的 5.1。

```powershell
git clone https://github.com/SynKairos/dsh-wsl-tray
cd dsh-wsl-tray
pwsh -ExecutionPolicy Bypass -File tools\install.ps1        # 文件 + unit + linger + 快捷方式 + 自检
```

> 为什么要 `-ExecutionPolicy Bypass`：Windows 默认 `RemoteSigned` 会拒绝执行未签名脚本，
> 而放在 `\\wsl.localhost\...`（网络路径）上的脚本一律算「远程」。把仓库拷到本机磁盘
> （如 `C:\Users\<你>\dsh-wsl-tray`）后，这个参数就可以省略。

安装不会启动服务，也不会动正在运行的 dsh；装完后双击桌面上的 `DeepSeek Harness`，
托盘会自己 `systemctl --user start`。install 会把 unit **disable** 掉（不是 enable）：
服务只由托盘启动，避免"开了个终端 dsh 就自己跑起来"。

从旧版本升级（托盘原本自己持有 dsh 进程）请走 [`MIGRATION.md`](MIGRATION.md)：
`tools\switch.ps1` 会备份、安装、停旧实例、启动 unit、重开托盘。

## 配置

全部机器相关项都在 `tray/dsh-tray.config.json`（部署后在
`%LOCALAPPDATA%\dsh\dsh-tray.config.json`）。改完可直接 `-ConfigTest` 看解析结果。

| 键 | 默认 | 说明 |
|---|---|---|
| `distro` | `Ubuntu-24.04` | WSL 发行版名 |
| `user` | `""` | 发行版账号；空 = Windows 用户名小写 |
| `host` / `port` | `127.0.0.1` / `3080` | 探测与打开 URL 用的地址 |
| `unit` | `dsh-web` | systemd 用户单元名 |
| `logPath` | `~/.local/state/dsh-web.log` | dsh 启动行（含 token）所在文件；**必须与 unit 的 `StandardOutput` 一致** |
| `stopConfirm` | `true` | 停止/重启前内联确认 |
| `startTimeoutSeconds` | `90` | 冷启动（含 WSL 引导）上限 |
| `stopTimeoutSeconds` | `25` | 面板里「停止服务」等待端口释放的上限 |
| `exitStopTimeoutSeconds` | `10` | 退出路径停服务的上限，超时对 cgroup 发 SIGKILL |
| `pollSeconds` | `3` | 状态轮询间隔 |
| `focusBrowser` | `true` | token 未变时优先聚焦已开的标签 |
| `stopOnExit` | `true` | 退出时停服务；`false` 时「停止服务」留在托盘、另有「退出托盘」保留服务（keeper 不进 Job） |
| `prewarmPanel` | `true` | 启动时离屏预热面板；怀疑启动闪烁可关掉做二分 |

> 改端口要动两处：`config.port`（托盘探测与打开 URL）和 unit 的 `Environment=DSH_PORT`
> （dsh 实际监听）。`install.ps1` 在两者不一致时会告警。
> 工作区由 unit 的 `DSH_WORKSPACE` 决定（默认 `~/dsh-workspace`，见
> `systemd/dsh-web.service`），托盘配置里不重复声明。

## 自检开关（都不需要 GUI）

| 开关 | 作用 |
|---|---|
| `-Probe <port>` | 端口归属：`free` / `dsh` / `foreign` |
| `-TokenTest` | token 能否读到（只打印长度与哈希，不打印 token） |
| `-ConfigTest` | 打印解析后的配置、日志路径与关键文件是否存在 |
| `-ControllerTest` | 打印将执行的 systemctl 命令、unit 状态（不启停） |
| `-KeeperTest` | 拉起 keeper 并报告存活；`stopOnExit=true` 时进程退出会由 Job Object 回收，`false` 时故意留下 |
| `-ReleaseTest` | 单独验证 keeper 释放路径（服务未运行时才生效） |
| `-ExitTest` | **完整退出路径**：起服 → 走真实 `Exit-App` → 断言端口与 keeper 归零 |
| `-PrewarmTest` | 预热探针：应输出 `panel_created=False`（启动时不得存在任何面板窗口） |
| `-Render -RenderState running\|starting\|stopping\|stopped\|failed [-RenderReason stop\|port\|token\|linger\|nounit] [-RenderConfirm stop\|restart]` | 离屏渲染面板到 `%LOCALAPPDATA%\dsh\panel-*.png` |
| `-SelfTest` | 跑一轮「停止 → 启动」，量心跳最大间隔，结果写 `selftest.txt` |
| `-AnchorTest -AnchorState <s> -CursorX <px> -CursorY <px>` | 打印 DPI 缩放、工作区、面板四边、是否越界 |
| `-AnimTest` | 采样渐入/渐出透明度与 `IsVisible` |
| `-ListWindows` / `-FocusTest` | 诊断左键聚焦（枚举窗口 / 真实激活并回读前台 hwnd） |
| `-NoStart` | 只出托盘，不拉起 dsh（服务已在跑时用） |

`-ExitTest` / `-ReleaseTest` / `-SelfTest` 会先检查单实例互斥量：托盘在运行时直接打印
abort 并 `exit 2`，避免诊断工具把正在用的实例拆掉。

环境变量 `DSH_TRAY_ROOT` 可把脚本的「安装根」指到任意目录（用于在不碰部署目录的
前提下跑 `-Render` / `-ConfigTest`）。

## 排障

| 现象 | 先看 |
|---|---|
| 双击没反应 | `%LOCALAPPDATA%\dsh\tray.log`；控件缺失时会有弹窗直接指出路径 |
| 面板红点「启动失败 · 服务单元未安装」 | 跑 `tools\install.ps1` |
| 面板红点「systemd 未运行」 | `loginctl enable-linger <user>`，并确认 `ps -p 1` 是 systemd |
| 面板红点「未取到访问令牌」 | 日志里是否有 `dsh web: ...?token=`；dsh 配置里 `printUrl` 必须保持 true |
| 端口被占 | `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/`，401 才是 dsh |
| 服务起不来 | `journalctl --user -u dsh-web -n 50`；`systemctl --user status dsh-web` |
| 退出后端口还在 | `tray.log` 里找 `exit: service stopped=`；`systemctl --user is-active dsh-web` |
| 想临时只出托盘 | `dsh-tray.vbs` 之后用 `-NoStart`，或直接双击快捷方式（会自动启动） |

## 已知限制

- **只按主屏定位**。多显示器、不同 DPI 混用时面板会落到主屏。
- **后台标签退化**：窗口标题只反映当前激活标签，dsh 在后台标签时左键会新开标签。
- **token 随每次启动变化**。复用旧标签前会比对 `last-token.sha`（只存 SHA256），
  不匹配就开新标签；日志里 `[boot]` 标记之前的 token 一律视为过期。
- **`%LOCALAPPDATA%` 下才自洽**：`.vbs`/`.ps1`/图标/文案/配置必须在同一目录。
- 托盘基于 WPF，常驻约 200–250 MB。
- **服务存活依赖 keeper 客户端**：默认模式下托盘退出、`wsl --shutdown`、注销或重启都会终止
  它，服务随之停止（这是 WSL 的边界；本方案不做开机自启，按需双击快捷方式）。
- 图标缩到 16 px 时标记仍偏细：已按尺寸分别构图（小尺寸放大标记占比），但 koi 本身细节多。

## 安全说明

- token 从 `~/.local/state/dsh-web.log` 读取（dsh 启动时打印）。脚本**不落盘明文 token**，
  只写 `last-token.sha`（SHA256，用于判断标签是否过期）。
- 该日志本身含明文 token，且默认由 systemd 以 0644 创建；如需收紧，在 unit 的
  `[Service]` 里加 `UMask=0077`（新建的日志即 600，已存在的需 `chmod 600` 一次）。
- 托盘只监听本机；它不开放任何端口，也不代理流量。

## 关于 PowerShell

只有一个 `dsh-tray.ps1` 是 PowerShell（约 2200 行、74 个函数），其余是 137 行 bash 加一个
unit。选择它的理由是零构建、零依赖：WPF、`System.Drawing`、CIM 查询、COM 建快捷方式都在
系统里，改一行存盘即生效。代价是 5.1 按 ANSI 解析（脚本必须纯 ASCII）、`add_Tick` 的
scriptblock 不捕获局部变量（状态因此集中在 `$script:` 作用域）。若将来要做安装包、自动更新
或代码签名，更合适的形态是 .NET + WPF 单文件发布。

## 许可

MIT，见 [LICENSE](LICENSE)。
