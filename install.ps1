[CmdletBinding()]
param(
    [string]$InstallRoot,
    [switch]$SkipCodex,
    [switch]$SkipClaude,
    [switch]$SkipPi
)

$ErrorActionPreference = 'Stop'
$userHome = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrWhiteSpace($userHome)) { throw 'Cannot resolve the Windows user profile.' }
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path $userHome '.agent-hooks\windows-notify'
}

function Backup-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $Path -Destination "$Path.bak-windows-notify-$stamp" -Force
}

function Get-JsonHashtable([string]$Path, $Default) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $Default }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable)
}

function Save-JsonHashtable([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Path $parent -Force
    $Value | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Test-HookCommand($Groups, [string]$Command) {
    foreach ($group in @($Groups)) {
        if ($null -eq $group -or -not $group.ContainsKey('hooks')) { continue }
        foreach ($handler in @($group.hooks)) {
            if ($null -eq $handler) { continue }
            if (($handler.ContainsKey('commandWindows') -and [string]$handler.commandWindows -eq $Command) -or
                ($handler.ContainsKey('command') -and [string]$handler.command -eq $Command)) { return $true }
        }
    }
    return $false
}

$null = New-Item -ItemType Directory -Path $InstallRoot -Force
foreach ($name in @('shared', 'adapters')) {
    $source = Join-Path $PSScriptRoot $name
    $dest = Join-Path $InstallRoot $name
    $null = New-Item -ItemType Directory -Path $dest -Force
    Copy-Item -Path (Join-Path $source '*') -Destination $dest -Recurse -Force
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'notify-config.json') -Destination (Join-Path $InstallRoot 'notify-config.json') -Force

if (-not $SkipCodex) {
    $hooksPath = Join-Path $userHome '.codex\hooks.json'
    $doc = Get-JsonHashtable -Path $hooksPath -Default ([ordered]@{ hooks = [ordered]@{} })
    if (-not $doc.ContainsKey('hooks') -or $null -eq $doc.hooks) { $doc.hooks = [ordered]@{} }
    $changed = $false

    if (-not $doc.hooks.ContainsKey('Stop')) { $doc.hooks.Stop = @() }
    $stopCommand = 'cmd.exe /d /c ' + (Join-Path $InstallRoot 'adapters\codex-stop.cmd')
    if (-not (Test-HookCommand -Groups $doc.hooks.Stop -Command $stopCommand)) {
        $doc.hooks.Stop = @($doc.hooks.Stop) + @([ordered]@{
            hooks = @([ordered]@{
                type = 'command'
                command = $stopCommand
                commandWindows = $stopCommand
                timeout = 15
            })
        })
        $changed = $true
    }

    $attentionCommand = 'cmd.exe /d /c ' + (Join-Path $InstallRoot 'adapters\codex-attention.cmd')
    if (-not $doc.hooks.ContainsKey('PreToolUse')) { $doc.hooks.PreToolUse = @() }
    if (-not (Test-HookCommand -Groups $doc.hooks.PreToolUse -Command $attentionCommand)) {
        $doc.hooks.PreToolUse = @($doc.hooks.PreToolUse) + @([ordered]@{
            matcher = 'request_user_input'
            hooks = @([ordered]@{
                type = 'command'
                command = $attentionCommand
                commandWindows = $attentionCommand
                timeout = 15
            })
        })
        $changed = $true
    }

    if (-not $doc.hooks.ContainsKey('PermissionRequest')) { $doc.hooks.PermissionRequest = @() }
    if (-not (Test-HookCommand -Groups $doc.hooks.PermissionRequest -Command $attentionCommand)) {
        $doc.hooks.PermissionRequest = @($doc.hooks.PermissionRequest) + @([ordered]@{
            hooks = @([ordered]@{
                type = 'command'
                command = $attentionCommand
                commandWindows = $attentionCommand
                timeout = 15
            })
        })
        $changed = $true
    }

    if ($changed) {
        Backup-File $hooksPath
        Save-JsonHashtable -Path $hooksPath -Value $doc
    }
}

if (-not $SkipClaude) {
    $settingsPath = Join-Path $userHome '.claude\settings.json'
    $doc = Get-JsonHashtable -Path $settingsPath -Default ([ordered]@{})
    if (-not $doc.ContainsKey('hooks') -or $null -eq $doc.hooks) { $doc.hooks = [ordered]@{} }
    if (-not $doc.hooks.ContainsKey('Stop')) { $doc.hooks.Stop = @() }

    # Claude Code 2.1.x supports exec-form command hooks. Use it on Windows so the
    # Stop JSON goes directly to PowerShell stdin instead of passing through a nested
    # cmd.exe shell, which can consume the JSON as interactive command input.
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = Join-Path $InstallRoot 'adapters\claude-stop.ps1'
    $legacyCommand = 'cmd.exe /d /c ' + (Join-Path $InstallRoot 'adapters\claude-stop.cmd')
    $handler = [ordered]@{
        type = 'command'
        command = $powershellExe
        args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
        timeout = 15
    }

    $found = $false
    $changed = $false
    foreach ($group in @($doc.hooks.Stop)) {
        if ($null -eq $group -or -not $group.ContainsKey('hooks')) { continue }
        for ($i = 0; $i -lt @($group.hooks).Count; $i++) {
            $existing = @($group.hooks)[$i]
            if ($null -eq $existing -or -not $existing.ContainsKey('command')) { continue }
            $existingCommand = [string]$existing.command
            $existingArgs = if ($existing.ContainsKey('args')) { @($existing.args) } else { @() }
            $isLegacy = $existingCommand -eq $legacyCommand
            $argsMatch = ($existingArgs.Count -eq $handler.args.Count) -and (($existingArgs -join "`0") -eq (@($handler.args) -join "`0"))
            $isExec = ($existingCommand -eq $powershellExe) -and $argsMatch
            $isRelatedExec = ($existingCommand -eq $powershellExe) -and ($existingArgs -contains $scriptPath)
            if (-not ($isLegacy -or $isExec -or $isRelatedExec)) { continue }

            if (-not $isExec -or $existing.timeout -ne 15) {
                $group.hooks[$i] = $handler
                $changed = $true
            }
            $found = $true
        }
    }

    if (-not $found) {
        $doc.hooks.Stop = @($doc.hooks.Stop) + @([ordered]@{ hooks = @($handler) })
        $changed = $true
    }

    $attentionScriptPath = Join-Path $InstallRoot 'adapters\claude-attention.ps1'
    $attentionArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $attentionScriptPath)
    $attentionSpecs = @(
        [ordered]@{ event = 'PreToolUse'; matcher = 'AskUserQuestion' },
        [ordered]@{ event = 'Notification'; matcher = 'permission_prompt' },
        [ordered]@{ event = 'Notification'; matcher = 'elicitation_dialog' },
        [ordered]@{ event = 'Notification'; matcher = 'agent_needs_input' }
    )

    foreach ($spec in $attentionSpecs) {
        $eventName = [string]$spec.event
        $matcher = [string]$spec.matcher
        if (-not $doc.hooks.ContainsKey($eventName)) { $doc.hooks[$eventName] = @() }

        $exists = $false
        foreach ($group in @($doc.hooks[$eventName])) {
            if ($null -eq $group -or [string]$group.matcher -ne $matcher -or -not $group.ContainsKey('hooks')) { continue }
            foreach ($existing in @($group.hooks)) {
                if ($null -eq $existing -or -not $existing.ContainsKey('command')) { continue }
                $existingArgs = if ($existing.ContainsKey('args')) { @($existing.args) } else { @() }
                $argsMatch = ($existingArgs.Count -eq $attentionArgs.Count) -and (($existingArgs -join "`0") -eq ($attentionArgs -join "`0"))
                if ([string]$existing.command -eq $powershellExe -and $argsMatch) {
                    $exists = $true
                    break
                }
            }
            if ($exists) { break }
        }

        if (-not $exists) {
            $doc.hooks[$eventName] = @($doc.hooks[$eventName]) + @([ordered]@{
                matcher = $matcher
                hooks = @([ordered]@{
                    type = 'command'
                    command = $powershellExe
                    args = $attentionArgs
                    timeout = 15
                })
            })
            $changed = $true
        }
    }

    if ($changed) {
        Backup-File $settingsPath
        Save-JsonHashtable -Path $settingsPath -Value $doc
    }
}

if (-not $SkipPi) {
    $piExtensions = Join-Path $userHome '.pi\agent\extensions'
    $piTarget = Join-Path $piExtensions 'windows-notify.ts'
    $piSource = 'git:https://github.com/nonlog/windows-cli-notify'
    $piCommand = Get-Command pi -ErrorAction SilentlyContinue
    if ($null -ne $piCommand) {
        if (Test-Path -LiteralPath $piTarget -PathType Leaf) {
            Backup-File $piTarget
            Remove-Item -LiteralPath $piTarget -Force
        }
        $piList = (& pi list 2>$null | Out-String)
        if ($piList -notmatch [regex]::Escape($piSource)) {
            & pi install $piSource
            if ($LASTEXITCODE -ne 0) { throw "Pi package install failed: $piSource" }
        }
    } else {
        $null = New-Item -ItemType Directory -Path $piExtensions -Force
        Backup-File $piTarget
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'adapters\pi-windows-notify.ts') -Destination $piTarget -Force
    }
}

Write-Host "Installed shared notifier to: $InstallRoot"
if (-not $SkipCodex) { Write-Host 'Codex: open /hooks once and trust the windows-notify Stop, PreToolUse, and PermissionRequest hooks.' }
if (-not $SkipClaude) { Write-Host 'Claude Code: completion and attention hooks merged into ~/.claude/settings.json.' }
if (-not $SkipPi) { Write-Host 'Pi: Git package installed from nonlog/windows-cli-notify (local-copy fallback only when pi is unavailable).' }
