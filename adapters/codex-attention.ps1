$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'shared\notify-lib.ps1')
. (Join-Path $PSScriptRoot 'codex-common.ps1')

try {
    $raw = Read-AgentNotifyStdinUtf8
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $event = $raw | ConvertFrom-Json
    if (-not (Test-CodexHookEventUserFacing -Event $event)) { exit 0 }

    $hookEvent = [string]$event.hook_event_name
    if ($hookEvent -eq 'PreToolUse') {
        if ([string]$event.tool_name -ne 'request_user_input') { exit 0 }
        $message = Get-AgentQuestionSummary -Questions $event.tool_input.questions
        if ([string]::IsNullOrWhiteSpace($message)) { $message = 'Codex is waiting for your input.' }
        $payload = [pscustomobject]@{
            source = 'Codex'
            event = 'needs_input'
            title = 'Codex needs input'
            message = $message
            cwd = [string]$event.cwd
        }
    } elseif ($hookEvent -eq 'PermissionRequest') {
        $toolName = [string]$event.tool_name
        $message = if ([string]::IsNullOrWhiteSpace($toolName)) {
            'Codex is waiting for permission.'
        } else {
            "Permission requested for: $toolName"
        }
        $payload = [pscustomobject]@{
            source = 'Codex'
            event = 'permission'
            title = 'Codex permission required'
            message = $message
            cwd = [string]$event.cwd
        }
    } else {
        exit 0
    }

    [void](Send-AgentNotification -Payload $payload)
} catch {
    Write-AgentNotifyLog -Message ("Codex attention adapter failed: " + $_.Exception.Message)
}
exit 0
