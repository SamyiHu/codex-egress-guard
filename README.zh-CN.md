# Codex Egress Guard（中文说明）

按程序隔离的 Windows 防火墙护栏：阻止 OpenAI Codex / ChatGPT 程序**直连公网（Internet 出站）**，同时放行回环与本地/内网流量，本地桥和代理不受影响。

只针对 `codex.exe` / `ChatGPT.exe` 及打包它们的 MSIX 应用，不碰其他进程（本地桥、`node.exe`、模型提供方、浏览器等）。

## 各目标的封锁方式

| 目标 | 机制 | 原因 |
|---|---|---|
| 商店 / MSIX 打包版（`ChatGPT.exe` + 内置 `codex.exe`） | 一条按**包族名（PackageFamilyName）**作用域的出站阻止规则 | 按程序路径建的规则**拦不住**打包应用的流量，而且 `WindowsApps` 下带版本号的安装路径每次更新都会变；按包族建规则既有效又不怕更新 |
| VS Code 扩展里的 `codex.exe`（`openai.chatgpt-*`） | 精确路径出站阻止规则 | 普通 Win32 程序，路径规则有效 |
| 本地安装的 Codex CLI（`%LOCALAPPDATA%\OpenAI\Codex\bin\...`） | 精确路径出站阻止规则 | 普通 Win32 程序，路径规则有效 |

每次执行 **Blocked**（封锁）动作都会重新扫描目标：清理指向已不存在路径的过期规则，为新路径/包补建规则。应用更新后再跑一次即可。

每条规则均为：方向 `Outbound` / 动作 `Block` / 远程地址 `Internet` / 所有配置文件。`Internet` 地址集**设计上**不包含回环和本地/内网地址——应用仍能访问本地桥或代理，只是无法自己直连公网。

## 它不拦截什么

由 Microsoft Store / Windows Update 基础设施投递的**应用更新**。商店打包应用从不自己下载更新：应用内的"更新"按钮调用的是系统服务（`Windows.Services.Store`），实际下载和安装由系统进程完成。本工具只针对应用二进制，所以应用仍会通过系统渠道自更新——这是预期行为，不是 bug。

## 一键脚本

命名说明：脚本操作的对象是"外联"—— Disable 外联 = 封锁，Enable 外联 = 放行。

- `Disable-Codex-External-Egress.cmd` — 封锁外联（启用规则）
- `Enable-Codex-External-Egress.cmd` — 放行外联（停用规则）
- `Status-Codex-External-Egress.cmd` — 查看当前规则状态

改变状态会弹 UAC 提权（脚本自动提权）；`Status` 无需管理员。

PowerShell 等价命令：

```powershell
.\Set-CodexEgressPolicy.ps1 -State Blocked   # 或 Allowed / Status / Reset
.\Set-CodexEgressPolicy.ps1 -State Reset     # 彻底删除所有护栏规则
```

`Status` 同时会在脚本旁生成 `codex-egress-status.json`，包含完整规则清单（作用域、程序/包、启用状态）。

## 环境要求

- Windows 10 / 11，自带 Windows PowerShell 5.1（无需安装任何模块）
- 至少装了其中一样：OpenAI Codex/ChatGPT 商店应用、VS Code ChatGPT 扩展、本地 Codex CLI。一个都没有时 `Blocked` 会直接报错。

## 仓库文件

```
Set-CodexEgressPolicy.ps1          核心脚本（Blocked / Allowed / Status / Reset）
Disable-Codex-External-Egress.cmd  一键：封锁
Enable-Codex-External-Egress.cmd   一键：放行
Status-Codex-External-Egress.cmd   一键：查状态
Test-AllowState.ps1                测试工具：停用全部护栏规则并记录日志
```

`codex-egress-status.json`、`last-action.txt`、`*.log` 为机器生成的状态文件，不入库。

## 许可

[MIT](LICENSE)
