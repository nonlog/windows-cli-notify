$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'shared\notify-lib.ps1')

try {
    $raw = Read-AgentNotifyStdinUtf8
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $event = $raw | ConvertFrom-Json
    $hookEvent = [string]$event.hook_event_name

    if ($hookEvent -eq 'PreToolUse') {
        if ([string]$event.tool_name -ne 'AskUserQuestion') { exit 0 }
        $message = Get-AgentQuestionSummary -Questions $event.tool_input.questions
        if ([string]::IsNullOrWhiteSpace($message)) { $message = 'Claude Code is waiting for your input.' }
        $payload = [pscustomobject]@{
            source = 'Claude Code'
            event = 'needs_input'
            title = 'Claude Code needs input'
            message = $message
            cwd = [string]$event.cwd
        }
    } elseif ($hookEvent -eq 'Notification') {
        $notificationType = [string]$event.notification_type
        if ($notificationType -notin @('permission_prompt', 'elicitation_dialog', 'agent_needs_input')) { exit 0 }
        $message = [string]$event.message
        if ([string]::IsNullOrWhiteSpace($message)) { $message = 'Claude Code is waiting for your input.' }
        $title = [string]$event.title
        if ([string]::IsNullOrWhiteSpace($title)) { $title = 'Claude Code needs input' }
        $payload = [pscustomobject]@{
            source = 'Claude Code'
            event = 'needs_input'
            title = $title
            message = $message
            cwd = [string]$event.cwd
        }
    } else {
        exit 0
    }

    [void](Send-AgentNotification -Payload $payload)
} catch {
    Write-AgentNotifyLog -Message ("Claude attention adapter failed: " + $_.Exception.Message)
}
exit 0
