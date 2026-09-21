$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('agent-notify-' + [guid]::NewGuid().ToString('N') + '.json')
$env:AI_CLI_NOTIFY_DRY_RUN = '1'
$env:AI_CLI_NOTIFY_FORCE = '1'
$env:AI_CLI_NOTIFY_TEST_OUTPUT = $temp
try {
    $codexMessage = 'Codex 完成：中文通知 ✅'
    $codexCwd = 'C:\工作\codex'
    $codex = @{ hook_event_name='Stop'; session_id='s1'; turn_id='t1'; cwd=$codexCwd; last_assistant_message=$codexMessage } | ConvertTo-Json -Compress
    $codex | & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\codex-stop.ps1')
    $result = Get-Content -LiteralPath $temp -Raw | ConvertFrom-Json
    if ($result.source -ne 'Codex' -or $result.message -ne $codexMessage -or $result.cwd -ne $codexCwd) { throw 'Codex adapter UTF-8 smoke test failed.' }

    Remove-Item -LiteralPath $temp -Force
    $claudeMessage = 'Claude 完成：乱码修复 🚀'
    $claudeCwd = 'C:\工作\claude'
    $claude = @{ hook_event_name='Stop'; session_id='s2'; cwd=$claudeCwd; last_assistant_message=$claudeMessage } | ConvertTo-Json -Compress
    $claude | & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\claude-stop.ps1')
    $result = Get-Content -LiteralPath $temp -Raw | ConvertFrom-Json
    if ($result.source -ne 'Claude Code' -or $result.message -ne $claudeMessage -or $result.cwd -ne $claudeCwd) { throw 'Claude adapter UTF-8 smoke test failed.' }

    Remove-Item -LiteralPath $temp -Force
    $piMessage = 'Pi 完成：中文 + emoji 🎉'
    $piCwd = 'C:\工作\pi'
    $pi = @{ source='Pi'; event='complete'; title='Pi completed'; message=$piMessage; cwd=$piCwd } | ConvertTo-Json -Compress
    $pi | & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'shared\notify.ps1')
    $result = Get-Content -LiteralPath $temp -Raw | ConvertFrom-Json
    if ($result.source -ne 'Pi' -or $result.message -ne $piMessage -or $result.cwd -ne $piCwd) { throw 'Pi/shared notifier UTF-8 smoke test failed.' }

    Write-Host 'Windows notify adapter UTF-8 smoke tests passed.'
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    Remove-Item Env:AI_CLI_NOTIFY_DRY_RUN -ErrorAction SilentlyContinue
    Remove-Item Env:AI_CLI_NOTIFY_FORCE -ErrorAction SilentlyContinue
    Remove-Item Env:AI_CLI_NOTIFY_TEST_OUTPUT -ErrorAction SilentlyContinue
}