param([string]$Lua = 'lua', [string]$Luau = 'luau')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $taskRoot
try {
    New-Item -ItemType Directory -Force -Path 'tests/.generated' | Out-Null
    & $Lua 'tests/test_acceleration.lua'
    if ($LASTEXITCODE -ne 0) { throw 'Acceleration host checks failed' }
    $taskExecutable = (Get-Command $Luau -ErrorAction Stop).Source
    foreach ($taskCase in Get-Content -LiteralPath 'tests/.generated/acceleration_manifest.txt') {
        if ($taskCase -notmatch '^[a-z0-9_]+$') { throw "Invalid acceleration case: $taskCase" }
        $taskPath = (Resolve-Path -LiteralPath "tests/.generated/acceleration_$taskCase.luau").ProviderPath
        $taskStart = [System.Diagnostics.ProcessStartInfo]::new()
        $taskStart.FileName = $taskExecutable
        $taskStart.Arguments = '"' + $taskPath + '"'
        $taskStart.UseShellExecute = $false
        $taskStart.CreateNoWindow = $true
        $taskStart.RedirectStandardOutput = $true
        $taskStart.RedirectStandardError = $true
        $taskProcess = [System.Diagnostics.Process]::new()
        $taskProcess.StartInfo = $taskStart
        try {
            if (-not $taskProcess.Start()) { throw "Acceleration process did not start: $taskCase" }
            $taskOutput = $taskProcess.StandardOutput.ReadToEndAsync()
            $taskError = $taskProcess.StandardError.ReadToEndAsync()
            if (-not $taskProcess.WaitForExit(30000)) {
                try { $taskProcess.Kill($true) } catch { $taskProcess.Kill() }
                throw "Acceleration fixture timed out: $taskCase"
            }
            $taskText = $taskOutput.GetAwaiter().GetResult().Trim()
            $taskDiagnostics = $taskError.GetAwaiter().GetResult()
            if ($taskProcess.ExitCode -ne 0 -or $taskText -ne "acceleration $taskCase OK") {
                throw "Acceleration fixture failed: $taskCase`n$taskText`n$taskDiagnostics"
            }
            Write-Output $taskText
        } finally { $taskProcess.Dispose() }
    }
    Write-Output 'All acceleration checks passed'
} finally { Pop-Location }
