# Windows notifications for Codex CLI, Claude Code, and Pi

A shared Windows 11 toast notifier with thin adapters for Codex CLI, Claude Code, and Pi.

## Design

- **Codex CLI**: user-level `Stop` hook. Current Codex sends the hook JSON over stdin, including `cwd` and `last_assistant_message`. This deliberately avoids the legacy `notify = [...]` argv payload, which can hit the Windows command-line length limit on long turns.
- **Claude Code**: user-level `Stop` hook. It consumes `last_assistant_message` directly instead of racing the transcript file. On Windows the installer uses Claude Code exec-form hooks (`powershell.exe` + `args`) so stdin reaches the adapter without a nested `cmd.exe` shell.
- **Pi**: extension records the last `turn_end` assistant text and sends the notification on `agent_settled`, so retries, compaction recovery, or queued continuation do not trigger a premature toast. The handler awaits the short-lived PowerShell notifier (hard-capped at 3 seconds) so print-mode shutdown cannot terminate it before the toast is submitted.
- **Shared layer**: Windows PowerShell 5.1/WinRT `ToastNotificationManager`. PowerShell 7 runs the installer, while the toast adapters use Windows PowerShell 5.1 because its .NET Framework host exposes the legacy `ContentType=WindowsRuntime` projection directly. PowerShell 7 runs on modern .NET and needs additional Windows SDK .NET interop assemblies for the same projection; this project avoids that dependency.

The default AppUserModelID is Windows Terminal:

```text
Microsoft.WindowsTerminal_8wekyb3d8bbwe!App
```

That keeps the notification routed through an installed Windows application identity instead of requiring a custom Start-menu shortcut registration.

## Install

From this directory in PowerShell 7 (required by the installer for `ConvertFrom-Json -AsHashtable`):

```powershell
pwsh -NoProfile -File .\install.ps1
```

The installer is additive and idempotent:

- copies the shared runtime to `~/.agent-hooks/windows-notify`;
- appends one Codex `Stop` matcher group to the existing `~/.codex/hooks.json` without replacing title/tty7/other hooks;
- appends or migrates one Claude Code `Stop` matcher group in `~/.claude/settings.json` without replacing unrelated hooks; the Windows handler uses exec form rather than `cmd.exe`;
- installs Pi from `git:https://github.com/nonlog/windows-cli-notify`, so `pi update` can update the extension; an old local `~/.pi/agent/extensions/windows-notify.ts` copy is backed up and removed during migration;
- creates timestamped backups before modifying an existing config file.

Codex requires a one-time review for changed non-managed hooks. Open `/hooks` and trust the newly added `Stop` hook after installation.

## Windows Codex command workaround

Current Codex has a Windows hook runner bug when `commandWindows` contains embedded quoted paths. The installer therefore uses a space-free install root and configures a quote-free command such as:

```text
cmd.exe /d /c C:\Users\www\.agent-hooks\windows-notify\adapters\codex-stop.cmd
```

The batch wrapper may quote its own script paths safely after Codex has launched it.

## Foreground suppression

Foreground suppression is disabled by default so every completion can toast, even while Windows Terminal is in the foreground. Set this to `true` only if you explicitly want to suppress those notifications:

```json
{
  "suppressWhenWindowsTerminalForeground": false
}
```

The current implementation cannot reliably map a Windows Terminal HWND back to a specific `WT_SESSION`, so suppression is process-wide rather than tab-specific.

Set `AI_CLI_NOTIFY_FORCE=1` to bypass foreground suppression for testing.

## Configuration

Edit the installed `~/.agent-hooks/windows-notify/notify-config.json` or the repository copy before reinstalling:

```json
{
  "appId": "Microsoft.WindowsTerminal_8wekyb3d8bbwe!App",
  "maxMessageChars": 420,
  "maxCwdChars": 140,
  "suppressWhenWindowsTerminalForeground": false,
  "showWorkingDirectory": true,
  "logFailures": true
}
```

Failures are best-effort logged to `%LOCALAPPDATA%\AgentHooks\windows-notify.log` and never fail an agent turn.

Pi can also be installed independently with `pi install git:https://github.com/nonlog/windows-cli-notify`. When loaded as a Pi Git package, the extension uses the repository's bundled `shared/notify.ps1`; the `~/.agent-hooks/windows-notify` fallback remains for local/manual installs.

## Tests

Adapter parsing without a real toast:

```powershell
pwsh -NoProfile -File .\tests\smoke.ps1
```

Force one real toast:

```powershell
pwsh -NoProfile -File .\test-notification.ps1
```

## Event behavior

| CLI | Event | Why |
| --- | --- | --- |
| Codex CLI | `Stop` | Stable stdin payload; avoids legacy argv-size failure |
| Claude Code | `Stop` | Fires when the main agent finishes responding and exposes `last_assistant_message` |
| Pi | `agent_settled` | Fires only after retry/compaction/queued continuation is finished |

Subagents are intentionally not notified in the first version.
