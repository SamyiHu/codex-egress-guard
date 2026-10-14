# Codex Egress Guard

Per-app Windows Firewall guard that blocks **direct Internet egress** from the OpenAI Codex / ChatGPT desktop binaries, while leaving loopback and local/private traffic alone so local bridges and proxies keep working.

Targets only `codex.exe` / `ChatGPT.exe` and the MSIX package that ships them. It never touches other processes (your local bridge, `node.exe`, the model provider, the browser, ...).

## How each target is blocked

| Target | Mechanism | Why |
|---|---|---|
| MSIX / Microsoft Store packaged app (`ChatGPT.exe` + bundled `codex.exe`) | one outbound-block rule scoped to the **package family name** | path-based rules do **not** reliably match packaged-app traffic, and the versioned install path under `WindowsApps` changes on every update; package scoping is both *effective* and *update-proof* |
| VS Code extension's `codex.exe` (`openai.chatgpt-*`) | exact-path outbound-block rule | ordinary Win32 binary, path rules work |
| locally installed Codex CLI (`%LOCALAPPDATA%\OpenAI\Codex\bin\...`) | exact-path outbound-block rule | ordinary Win32 binary, path rules work |

Rule discovery runs on every **Blocked** action: current paths/packages are re-scanned, rules for paths that no longer exist are pruned, and new ones are created. Run it again after app updates.

Every rule is: Direction `Outbound` / Action `Block` / RemoteAddress `Internet` / all profiles. The `Internet` address set excludes loopback and local/private ranges **by design** — the app can still talk to a local bridge or proxy, it just cannot reach the public Internet on its own.

## What it does NOT block

Updates delivered by the Microsoft Store / Windows Update infrastructure. Store-packaged apps never download their own updates: the in-app "update" button calls OS services (`Windows.Services.Store`), and system processes fetch and install the package. This guard intentionally targets only the app binaries, so the app keeps self-updating through the OS channel — that is expected, not a bug.

## One-click actions

Naming note: the scripts act on the *egress* — "Disable" egress = block it, "Enable" egress = allow it.

- `Disable-Codex-External-Egress.cmd` — block external egress (enable the rules)
- `Enable-Codex-External-Egress.cmd` — allow external egress (disable the rules)
- `Status-Codex-External-Egress.cmd` — show current rule state

Windows shows a UAC prompt for state changes (the script elevates itself); `Status` runs without elevation.

PowerShell equivalent:

```powershell
.\Set-CodexEgressPolicy.ps1 -State Blocked   # or Allowed / Status / Reset
.\Set-CodexEgressPolicy.ps1 -State Reset     # remove all guard rules entirely
```

`Status` also writes `codex-egress-status.json` next to the script with the full rule list (scope, program/package, enabled state).

## Requirements

- Windows 10 / 11 with the built-in Windows PowerShell 5.1 (no modules to install)
- At least one of: the OpenAI Codex/ChatGPT Store app, the VS Code ChatGPT extension, or the local Codex CLI. The `Blocked` action fails loudly if none is found.

## Repository layout

```
Set-CodexEgressPolicy.ps1          core script (Blocked / Allowed / Status / Reset)
Disable-Codex-External-Egress.cmd  one-click: block
Enable-Codex-External-Egress.cmd   one-click: allow
Status-Codex-External-Egress.cmd   one-click: status
Test-AllowState.ps1                test utility: disable all guard rules and log the result
```

`codex-egress-status.json`, `last-action.txt` and `*.log` are machine-generated state and are not tracked.

## License

[MIT](LICENSE)
