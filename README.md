# Windows notifications for Codex CLI, Claude Code, and Pi

A shared Windows 11 toast notifier with thin adapters for Codex CLI, Claude Code, and Pi.

## Design

- **Codex CLI**: `Stop` sends completion notifications, `PreToolUse(request_user_input)` notifies when Codex asks a question, and `PermissionRequest` notifies when approval is needed. The `Stop` adapter suppresses known background/synthetic events (non-root transcript sources, stale historical replay, session mismatches, and internal `suggestions`/`exclude` control JSON) so background memory/suggestion jobs do not look like task completion.
- **Claude Code**: `Stop` sends completion notifications, `PreToolUse(AskUserQuestion)` notifies for structured questions, and selected `Notification` events (`permission_prompt`, `elicitation_dialog`, `agent_needs_input`) notify when user attention is required. On Windows the installer uses Claude Code exec-form hooks (`powershell.exe` + `args`) so stdin reaches the adapter without a nested `cmd.exe` shell.
- **Pi**: the extension records the last `turn_end` assistant text and sends completion on `agent_settled`. When `@juicesharp/rpiv-ask-user-question` is installed, it also listens to that plugin's stable `rpiv:ask-user:prompt` event and sends a question notification without modifying the plugin.
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
- appends Codex `Stop`, `PreToolUse(request_user_input)`, and `PermissionRequest` groups to the existing `~/.codex/hooks.json` without replacing unrelated hooks;
- appends or migrates Claude Code `Stop`, `PreToolUse(AskUserQuestion)`, and selected `Notification` groups in `~/.claude/settings.json` without replacing unrelated hooks; Windows handlers use exec form rather than `cmd.exe`;
- installs Pi from `git:https://github.com/nonlog/windows-cli-notify`, so `pi update` can update the extension; an old local `~/.pi/agent/extensions/windows-notify.ts` copy is backed up and removed during migration;
- creates timestamped backups before modifying an existing config file.

Codex requires a one-time review for changed non-managed hooks. Open `/hooks` and trust the `windows-cli-notify` `Stop`, `PreToolUse`, and `PermissionRequest` hooks after installation.

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

| CLI | Event | Notification |
| --- | --- | --- |
| Codex CLI | `Stop` | Foreground/root task completion after background-event filtering |
| Codex CLI | `PreToolUse(request_user_input)` | Codex asks the user a structured question |
| Codex CLI | `PermissionRequest` | Codex is waiting for approval |
| Claude Code | `Stop` | Main-agent completion |
| Claude Code | `PreToolUse(AskUserQuestion)` | Claude asks a structured question |
| Claude Code | `Notification` (`permission_prompt`, `elicitation_dialog`, `agent_needs_input`) | Claude requires user attention |
| Pi | `agent_settled` | Completion after retry/compaction/queued continuation is finished |
| Pi | `rpiv:ask-user:prompt` | Question emitted by `@juicesharp/rpiv-ask-user-question` |

Codex subagent/non-root transcript events are intentionally suppressed. Pi's question notification is optional and activates automatically when the ask-user-question plugin emits its public event.
