# dsh-wsl-tray

A Windows system-tray controller for **DeepSeek Harness (dsh)** running inside WSL2.

The service itself belongs to **systemd** (a user unit), not to the tray. The tray
only shows state, starts/stops the unit, and opens the Web UI with a fresh token —
so quitting or crashing the tray never interrupts a running session, and
`Restart=on-failure` brings dsh back after a crash.

> 个人项目，与 DeepSeek 官方无关。只在一台机器（Windows 11 + WSL2 Ubuntu-24.04 +
> systemd 255 + dsh 0.2.2-rc.5）上验证过，不保证通用。

---

## 工作方式

```
桌面快捷方式
  └─ wscript.exe  %LOCALAPPDATA%\dsh\dsh-tray.vbs          （无黑框）
      └─ pwsh 7（回退 powershell 5.1）-Sta -NoProfile -File dsh-tray.ps1
          ├─ NotifyIcon（托盘图标）
          ├─ 自绘 WPF 无边框面板（300 DIP，跟随光标定位）
          ├─ systemctl --user start|stop|restart dsh-web   （经 wsl.exe，一次性进程）
          └─ 读日志尾部取 token → 打开/聚焦浏览器标签

systemd（PID 1）── dsh-web.service ── bash -l ~/bin/dsh-serve.sh ── dsh web --no-open
                     127.0.0.1:3080，Restart=on-failure，日志 append 到
                     ~/.local/state/dsh-web.log
```

为什么不用「托盘持有 wsl.exe」：WSL2 在最后一个 `wsl.exe` 客户端退出时会回收该会话的
进程，`setsid`/`nohup` 也救不回来（实测：客户端退出 1 秒内进程消失）。把 dsh 挂在
systemd 下则不受影响（实测：客户端退出 10 秒后 unit 仍 `active`）。详见
[`MIGRATION.md`](MIGRATION.md)。

| 交互 | 行为 |
|---|---|
| 左键 | 已有 dsh 浏览器标签就聚焦它；否则用带 token 的 URL 开新标签（800 ms 去抖） |
| 右键 | 弹出面板：打开界面 / 重启服务 / 停止服务 /（失败态）打开日志 / 退出托盘 |
| 状态点 | 每 3 秒判定：绿=运行 琥珀=启动中/停止中 灰=停止 红=失败（附原因行） |
| 停止/重启 | 二次确认（可在配置里关闭），避免误杀正在跑的会话 |
| 退出托盘 | **只退托盘，不停服务** |

启动、停止、重启都是**异步状态机**：点击只负责 spawn，轮询由 400 ms 的
`DispatcherTimer` 驱动，UI 线程不再阻塞。停止会等到端口真正释放才算成功，否则报
「停止失败」，不会被下一轮探测悄悄抹平。

## 目录

| 路径 | 内容 |
|---|---|
| `tray/dsh-tray.ps1` | 托盘主程序（纯 ASCII，中文文案全部外置） |
| `tray/dsh-tray.vbs` | 免控制台启动器，路径全部取自环境变量 |
| `tray/dsh-labels.json` | 中文文案（UTF-8） |
| `tray/dsh-tray.config.json` | 唯一配置源：端口 / 发行版 / 账号 / unit / 日志路径 |
| `tray/dsh-icon.ico` | 7 档多尺寸图标 |
| `systemd/dsh-web.service` | 用户级 unit（Type=simple，Restart=on-failure） |
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

安装不会启动服务，也不会动正在运行的 dsh。装完后双击桌面上的 `DeepSeek Harness`，
托盘会自己 `systemctl --user start`。

unit 是 `enable` 的，并且已开启 linger：之后 WSL 发行版一旦启动（包括你自己开终端），
服务就会自动起来，不必等托盘。托盘只是控制器，随时可以退出。

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
| `stopConfirm` | `true` | 停止/重启前二次确认 |
| `startTimeoutSeconds` | `90` | 冷启动（含 WSL 引导）上限 |
| `stopTimeoutSeconds` | `25` | 停止等待端口释放上限 |
| `pollSeconds` | `3` | 状态轮询间隔 |
| `focusBrowser` | `true` | token 未变时优先聚焦已开的标签 |

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
| `-Render -RenderState running\|starting\|stopping\|stopped\|failed [-RenderReason stop\|port\|token\|linger\|nounit]` | 离屏渲染面板到 `%LOCALAPPDATA%\dsh\panel-*.png` |
| `-SelfTest` | 跑一轮「停止 → 启动」，量心跳最大间隔，结果写 `selftest.txt` |
| `-AnchorTest -AnchorState <s> -CursorX <px> -CursorY <px>` | 打印 DPI 缩放、工作区、面板四边、是否越界 |
| `-AnimTest` | 采样渐入/渐出透明度与 `IsVisible` |
| `-ListWindows` / `-FocusTest` | 诊断左键聚焦（枚举窗口 / 真实激活并回读前台 hwnd） |
| `-NoStart` | 只出托盘，不拉起 dsh（服务已在跑时用） |

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
| 想临时只出托盘 | `dsh-tray.vbs` 之后用 `-NoStart`，或直接双击快捷方式（会自动启动） |

## 已知限制

- **只按主屏定位**。多显示器、不同 DPI 混用时面板会落到主屏。
- **后台标签退化**：窗口标题只反映当前激活标签，dsh 在后台标签时左键会新开标签。
- **token 随每次启动变化**。复用旧标签前会比对 `last-token.sha`（只存 SHA256），
  不匹配就开新标签；日志里 `[boot]` 标记之前的 token 一律视为过期。
- **`%LOCALAPPDATA%` 下才自洽**：`.vbs`/`.ps1`/图标/文案/配置必须在同一目录。
- 托盘基于 WPF，常驻约 200–250 MB。
- Windows 注销/重启会结束 WSL，服务随之停止（未做开机自启；按需双击快捷方式）。

## 安全说明

- token 从 `~/.local/state/dsh-web.log` 读取（dsh 启动时打印）。脚本**不落盘明文 token**，
  只写 `last-token.sha`（SHA256，用于判断标签是否过期）。
- 该日志本身含明文 token，且默认由 systemd 以 0644 创建；如需收紧，在 unit 的
  `[Service]` 里加 `UMask=0077`（新建的日志即 600，已存在的需 `chmod 600` 一次）。
- 托盘只监听本机；它不开放任何端口，也不代理流量。

## 许可

MIT，见 [LICENSE](LICENSE)。
