# dsh-wsl-tray

A Windows system-tray launcher for **DeepSeek Harness (dsh)** running inside WSL2.

WSL2 reclaims a distro when its last `wsl.exe` client exits, so a `nohup`/`setsid`-detached
`dsh` does not survive. The only stable arrangement is: a Windows process holds `wsl.exe`
in the foreground, and that process also gives you the UI for starting, stopping and
inspecting the service. This repository is that process.

> 个人项目，与 DeepSeek 官方无关。参数已外置，但只在一台机器（Windows 11 26200 +
> WSL2 Ubuntu-24.04 + dsh 0.2.2-rc.5）上验证过。不保证通用。

---

## 工作方式

```
桌面快捷方式
  └─ wscript.exe  %LOCALAPPDATA%\dsh\dsh-tray.vbs          （无黑框）
      └─ pwsh 7（回退 powershell 5.1）-Sta -NoProfile -File dsh-tray.ps1
          ├─ NotifyIcon（托盘图标）
          ├─ 自绘 WPF 无边框面板（300 DIP，跟随光标定位）
          └─ wsl.exe -d <distro> -- bash -l ~/bin/dsh-run.sh --no-browser
                 （前台持有 dsh web，127.0.0.1:3080）
```

| 交互 | 行为 |
|---|---|
| 左键 | 已有 dsh 浏览器标签就聚焦它；否则用带 token 的 URL 开新标签（800 ms 去抖） |
| 右键 | 弹出面板：打开界面 / 重启服务 / 停止服务 /（失败态）打开日志 / 退出托盘 |
| 状态点 | 每 3 秒判定：绿=运行 琥珀=启动中/停止中 灰=停止 红=失败（附原因行） |

启动、停止、重启都是**异步状态机**：点击只负责 spawn，轮询由 400 ms 的
`DispatcherTimer` 驱动，UI 线程不再阻塞（实测 6.3 s 阻塞 → 单次约 0.5 s 的建进程开销）。
停止会等到端口真正释放才算成功，否则报「停止失败」，不会被下一轮探测悄悄抹平。

## 目录

| 路径 | 内容 |
|---|---|
| `tray/dsh-tray.ps1` | 托盘主程序（纯 ASCII，中文文案全部外置） |
| `tray/dsh-tray.vbs` | 免控制台启动器，路径全部取自环境变量 |
| `tray/dsh-labels.json` | 中文文案（UTF-8） |
| `tray/dsh-icon.ico` | 7 档多尺寸图标 |
| `wsl/dsh-run.sh` | 前台启动器：幂等、端口冲突 exit 2、清掉 `all_proxy` |
| `wsl/dsh-stop.sh` | `pkill` + 等端口释放 |
| `wsl/dsh-log.sh` | 面板「打开日志」的 WSL 回退路径 |
| `tools/deploy-shortcut.ps1` | 重建桌面快捷方式 |
| `tools/verify-tray.ps1` | 不需要 GUI 的全链路静态校验 |
| `assets/panel.png` | 面板离屏渲染 |

## 安装

前提：WSL2 里已装好 dsh（本文假定 `dsh` 在 `~/.local/node/bin`，工作区 `~/dsh-workspace`）。

**WSL 侧**

```bash
mkdir -p ~/bin ~/dsh-workspace ~/.local/state
cp wsl/*.sh ~/bin/
sed -i 's/\r$//' ~/bin/dsh-*.sh && chmod 755 ~/bin/dsh-*.sh
```

**Windows 侧**

```powershell
$dst = "$env:LOCALAPPDATA\dsh"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item tray\* $dst -Force
pwsh -File tools\deploy-shortcut.ps1     # 重建桌面快捷方式并回读校验
pwsh -File tools\verify-tray.ps1         # 应输出 result=PASS
```

然后双击桌面上的 `DeepSeek Harness`。

## 配置

| 项 | 位置 | 说明 |
|---|---|---|
| 发行版名 | `dsh-tray.ps1 -Distro`，默认 `Ubuntu-24.04` | 或改文件头部默认值 |
| 发行版账号 | `-User`，默认为 **Windows 用户名的小写** | 两者不一致时显式传参 |
| 端口 | 脚本内 `3080`（多处） | 改端口需同步改 URL、探测与 `dsh-run.sh` |
| 文案 | `tray/dsh-labels.json` | 新增状态需同时补 key，缺 key 会退化为启动中文案 |
| 工作区 | 环境变量 `DSH_WORKSPACE`，默认 `~/dsh-workspace` | 由 `dsh-run.sh` 读取 |

## 自检开关（都不需要 GUI）

| 开关 | 作用 |
|---|---|
| `-Probe <port>` | 端口归属：`free` / `dsh` / `foreign` |
| `-TokenTest` | token 能否读到（只打印长度与哈希，不打印 token） |
| `-Render -RenderState running\|starting\|stopping\|stopped\|failed [-RenderReason stop\|port\|token]` | 离屏渲染面板到 `%LOCALAPPDATA%\dsh\panel-*.png` |
| `-SelfTest` | 跑一轮「停止 → 启动」，量心跳最大间隔，结果写 `selftest.txt` |
| `-AnchorTest -AnchorState <s> -CursorX <px> -CursorY <px>` | 打印 DPI 缩放、工作区、面板四边、是否越界 |
| `-AnimTest` | 采样渐入/渐出透明度与 `IsVisible` |
| `-ListWindows` / `-FocusTest` | 诊断左键聚焦（枚举窗口 / 真实激活并回读前台 hwnd） |
| `-NoStart` | 只出托盘，不拉起 dsh（服务已在跑时用） |

## 已知限制

- **只按主屏定位**。多显示器、不同 DPI 混用时面板会落到主屏。
- **后台标签退化**：窗口标题只反映当前激活标签，dsh 在后台标签时左键会新开标签。
- **token 会随 dsh 重启变化**。复用旧标签前会比对 `last-token.sha`（只存 SHA256），
  不匹配就开新标签，避免落到 401 页面。
- **`%LOCALAPPDATA%` 下才自洽**：`.vbs`/`.ps1`/图标/文案必须在同一目录，脚本按
  `$env:LOCALAPPDATA\dsh` 解析相对路径。
- 首次启动若 WSL 冷启动较慢，面板会显示「启动中」最多 90 秒，超时判失败。

## 安全说明

- token 从 `~/.local/state/dsh-web.log` 读取（dsh 启动时打印）。脚本**不落盘明文 token**，
  只写 `last-token.sha`（SHA256，用于判断标签是否过期）。
- 托盘只监听本机；它不开放任何端口。
- `dsh-run.sh` 会 unset `all_proxy`（dsh 不支持 socks 形式，会刷警告），`http_proxy` /
  `https_proxy` 保持生效。

## 许可

MIT，见 [LICENSE](LICENSE)。
