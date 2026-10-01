function Get-CodexTranscriptSessionMeta {
    param([AllowNull()] [string]$TranscriptPath)

    if ([string]::IsNullOrWhiteSpace($TranscriptPath) -or -not (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) {
        return $null
    }

    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($TranscriptPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true, 4096, $true)
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
        $entry = $line | ConvertFrom-Json
        if ([string]$entry.type -ne 'session_meta') { return $null }
        return $entry.payload
    } catch {
        return $null
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Test-CodexHookEventUserFacing {
    param(
        [Parameter(Mandatory)] $Event,
        [int]$MaxTranscriptAgeHours = 24
    )

    foreach ($name in @('agent_id', 'agent_type')) {
        $property = $Event.PSObject.Properties[$name]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return $false
        }
    }

    $transcriptPath = [string]$Event.transcript_path
    if ([string]::IsNullOrWhiteSpace($transcriptPath) -or -not (Test-Path -LiteralPath $transcriptPath -PathType Leaf)) {
        return $true
    }

    try {
        if ($MaxTranscriptAgeHours -gt 0) {
            $age = [DateTime]::UtcNow - (Get-Item -LiteralPath $transcriptPath).LastWriteTimeUtc
            if ($age.TotalHours -ge $MaxTranscriptAgeHours) { return $false }
        }

        $meta = Get-CodexTranscriptSessionMeta -TranscriptPath $transcriptPath
        if ($null -eq $meta) { return $true }

        $eventSessionId = [string]$Event.session_id
        $metaSessionId = [string]$meta.id
        if (-not [string]::IsNullOrWhiteSpace($eventSessionId) -and
            -not [string]::IsNullOrWhiteSpace($metaSessionId) -and
            $eventSessionId -ne $metaSessionId) {
            return $false
        }

        $sourceProperty = $meta.PSObject.Properties['source']
        if ($null -ne $sourceProperty -and $null -ne $sourceProperty.Value -and
            -not ($sourceProperty.Value -is [string])) {
            return $false
        }
    } catch {
        # Filtering is best-effort. A parser or filesystem failure must not hide
        # a real foreground notification.
        return $true
    }

    return $true
}

function Test-CodexInternalControlMessage {
    param([AllowNull()] [string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $trimmed = $Text.Trim()
    if (-not ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}'))) { return $false }

    try {
        $value = $trimmed | ConvertFrom-Json
        if ($null -eq $value -or $value -is [Array] -or $value -is [string]) { return $false }
        $properties = @($value.PSObject.Properties)
        if ($properties.Count -eq 0) { return $false }

        $internalKeys = @('suggestions', 'exclude')
        foreach ($property in $properties) {
            if ($property.Name -notin $internalKeys) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}
