$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('agent-notify-' + [guid]::NewGuid().ToString('N'))
$temp = Join-Path $tempDir 'snapshot.json'
$rootTranscript = Join-Path $tempDir 'root.jsonl'
$subagentTranscript = Join-Path $tempDir 'subagent.jsonl'
$staleTranscript = Join-Path $tempDir 'stale.jsonl'
$env:AI_CLI_NOTIFY_DRY_RUN = '1'
$env:AI_CLI_NOTIFY_FORCE = '1'
$env:AI_CLI_NOTIFY_TEST_OUTPUT = $temp
$ps5 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function Write-SessionMeta([string]$Path, [string]$Id, $Source) {
    $entry = [ordered]@{
        type = 'session_meta'
        payload = [ordered]@{
            id = $Id
            source = $Source
            cwd = 'C:\work'
        }
    }
    $entry | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $Path -Encoding utf8
}

function Invoke-Hook([string]$Script, $Payload) {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    $json = $Payload | ConvertTo-Json -Depth 20 -Compress
    $json | & $ps5 -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root $Script)
    if ($LASTEXITCODE -ne 0) { throw "Hook failed: $Script" }
}

function Read-Snapshot {
    if (-not (Test-Path -LiteralPath $temp -PathType Leaf)) { throw 'Expected notification snapshot was not written.' }
    return Get-Content -LiteralPath $temp -Raw | ConvertFrom-Json
}

function Assert-NoSnapshot([string]$Message) {
    if (Test-Path -LiteralPath $temp -PathType Leaf) { throw $Message }
}

try {
    $null = New-Item -ItemType Directory -Path $tempDir -Force
    Write-SessionMeta -Path $rootTranscript -Id 's1' -Source 'cli'
    Write-SessionMeta -Path $subagentTranscript -Id 's-sub' -Source ([ordered]@{ subagent = [ordered]@{ thread_spawn = [ordered]@{ depth = 1 } } })
    Write-SessionMeta -Path $staleTranscript -Id 's-stale' -Source 'cli'
    (Get-Item -LiteralPath $staleTranscript).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-48)

    $codexMessage = 'Codex 完成：中文通知 ✅'
    Invoke-Hook 'adapters\codex-stop.ps1' ([ordered]@{
        hook_event_name = 'Stop'
        session_id = 's1'
        turn_id = 't1'
        transcript_path = $rootTranscript
        cwd = 'C:\工作\codex'
        last_assistant_message = $codexMessage
    })
    $result = Read-Snapshot
    if ($result.source -ne 'Codex' -or $result.message -ne $codexMessage) { throw 'Codex completion smoke test failed.' }

    foreach ($internal in @('{"suggestions":[]}', '{"exclude":[]}')) {
        Invoke-Hook 'adapters\codex-stop.ps1' ([ordered]@{
            hook_event_name = 'Stop'
            session_id = 's1'
            turn_id = 't-internal'
            transcript_path = $rootTranscript
            cwd = 'C:\work'
            last_assistant_message = $internal
        })
        Assert-NoSnapshot "Codex internal control message was not filtered: $internal"
    }

    $legitJson = '{"result":"ok","suggestions":[]}'
    Invoke-Hook 'adapters\codex-stop.ps1' ([ordered]@{
        hook_event_name = 'Stop'
        session_id = 's1'
        turn_id = 't-json'
        transcript_path = $rootTranscript
        cwd = 'C:\work'
        last_assistant_message = $legitJson
    })
    $result = Read-Snapshot
    if ($result.message -ne $legitJson) { throw 'Legitimate Codex JSON output was incorrectly filtered.' }

    Invoke-Hook 'adapters\codex-stop.ps1' ([ordered]@{
        hook_event_name = 'Stop'
        session_id = 's-sub'
        turn_id = 't-sub'
        transcript_path = $subagentTranscript
        cwd = 'C:\work'
        last_assistant_message = 'Subagent finished'
    })
    Assert-NoSnapshot 'Codex subagent/background completion was not filtered.'

    Invoke-Hook 'adapters\codex-stop.ps1' ([ordered]@{
        hook_event_name = 'Stop'
        session_id = 's-stale'
        turn_id = 't-stale'
        transcript_path = $staleTranscript
        cwd = 'C:\work'
        last_assistant_message = 'Historical replay'
    })
    Assert-NoSnapshot 'Codex stale historical replay was not filtered.'

    Invoke-Hook 'adapters\codex-attention.ps1' ([ordered]@{
        hook_event_name = 'PreToolUse'
        session_id = 's1'
        turn_id = 't-question'
        transcript_path = $rootTranscript
        cwd = 'C:\工作\codex'
        tool_name = 'request_user_input'
        tool_use_id = 'q1'
        tool_input = [ordered]@{
            questions = @(
                [ordered]@{ question = '要使用哪个方案？'; header = '方案' },
                [ordered]@{ question = '是否继续？'; header = '继续' }
            )
        }
    })
    $result = Read-Snapshot
    if ($result.event -ne 'needs_input' -or $result.title -ne 'Codex needs input' -or $result.message -notmatch '要使用哪个方案') {
        throw 'Codex request_user_input notification failed.'
    }

    Invoke-Hook 'adapters\codex-attention.ps1' ([ordered]@{
        hook_event_name = 'PermissionRequest'
        session_id = 's1'
        turn_id = 't-permission'
        transcript_path = $rootTranscript
        cwd = 'C:\work'
        tool_name = 'Bash'
        tool_input = [ordered]@{}
    })
    $result = Read-Snapshot
    if ($result.event -ne 'permission' -or $result.title -ne 'Codex permission required') {
        throw 'Codex permission notification failed.'
    }

    Invoke-Hook 'adapters\claude-stop.ps1' ([ordered]@{
        hook_event_name = 'Stop'
        session_id = 's2'
        cwd = 'C:\工作\claude'
        last_assistant_message = 'Claude 完成：乱码修复 🚀'
    })
    $result = Read-Snapshot
    if ($result.source -ne 'Claude Code' -or $result.event -ne 'complete') { throw 'Claude completion smoke test failed.' }

    Invoke-Hook 'adapters\claude-attention.ps1' ([ordered]@{
        hook_event_name = 'PreToolUse'
        session_id = 's2'
        cwd = 'C:\工作\claude'
        tool_name = 'AskUserQuestion'
        tool_input = [ordered]@{
            questions = @([ordered]@{ question = 'Claude 需要你选择哪个选项？'; header = '选择' })
        }
    })
    $result = Read-Snapshot
    if ($result.event -ne 'needs_input' -or $result.message -notmatch 'Claude 需要你选择') {
        throw 'Claude AskUserQuestion notification failed.'
    }

    Invoke-Hook 'adapters\claude-attention.ps1' ([ordered]@{
        hook_event_name = 'Notification'
        session_id = 's2'
        cwd = 'C:\work'
        notification_type = 'permission_prompt'
        title = 'Permission needed'
        message = 'Claude Code needs permission.'
    })
    $result = Read-Snapshot
    if ($result.event -ne 'needs_input' -or $result.title -ne 'Permission needed') {
        throw 'Claude Notification attention test failed.'
    }

    Invoke-Hook 'adapters\claude-attention.ps1' ([ordered]@{
        hook_event_name = 'Notification'
        session_id = 's2'
        cwd = 'C:\work'
        notification_type = 'idle_prompt'
        message = 'Idle'
    })
    Assert-NoSnapshot 'Claude idle_prompt should not produce an attention notification.'

    Invoke-Hook 'shared\notify.ps1' ([ordered]@{
        source = 'Pi'
        event = 'complete'
        title = 'Pi completed'
        message = 'Pi 完成：中文 + emoji 🎉'
        cwd = 'C:\工作\pi'
    })
    $result = Read-Snapshot
    if ($result.source -ne 'Pi' -or $result.message -ne 'Pi 完成：中文 + emoji 🎉') {
        throw 'Pi/shared notifier UTF-8 smoke test failed.'
    }

    Remove-Item -LiteralPath $temp -Force
    & node (Join-Path $PSScriptRoot 'pi-question-smoke.ts')
    if ($LASTEXITCODE -ne 0) { throw 'Pi question event smoke test failed.' }

    Write-Host 'Windows notify completion, filtering, and attention smoke tests passed.'
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:AI_CLI_NOTIFY_DRY_RUN -ErrorAction SilentlyContinue
    Remove-Item Env:AI_CLI_NOTIFY_FORCE -ErrorAction SilentlyContinue
    Remove-Item Env:AI_CLI_NOTIFY_TEST_OUTPUT -ErrorAction SilentlyContinue
}
