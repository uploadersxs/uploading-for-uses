param([string]$Lua='lua',[string]$Luau='luau')
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $taskRoot
try {
    New-Item -ItemType Directory -Force -Path 'tests/.generated' | Out-Null
    function Invoke-LargeFixture([string]$Executable,[string]$Path,[int]$Deadline,[string]$Expected) {
        $taskStart=[System.Diagnostics.ProcessStartInfo]::new()
        $taskStart.FileName=(Get-Command $Executable -ErrorAction Stop).Source
        $taskStart.Arguments='"'+(Resolve-Path -LiteralPath $Path).ProviderPath+'"'
        $taskStart.WorkingDirectory=$taskRoot
        $taskStart.UseShellExecute=$false
        $taskStart.CreateNoWindow=$true
        $taskStart.RedirectStandardOutput=$true
        $taskStart.RedirectStandardError=$true
        $taskProcess=[System.Diagnostics.Process]::new()
        $taskProcess.StartInfo=$taskStart
        $taskWatch=[System.Diagnostics.Stopwatch]::StartNew()
        try {
            if (-not $taskProcess.Start()) { throw "Large fixture did not start: $Path" }
            $taskOutput=$taskProcess.StandardOutput.ReadToEndAsync()
            $taskError=$taskProcess.StandardError.ReadToEndAsync()
            if (-not $taskProcess.WaitForExit($Deadline*1000)) {
                try { $taskProcess.Kill($true) } catch { $taskProcess.Kill() }
                throw "Large fixture exceeded ${Deadline}s: $Path"
            }
            $taskWatch.Stop()
            $taskText=$taskOutput.GetAwaiter().GetResult().Trim()
            $taskDiagnostics=$taskError.GetAwaiter().GetResult()
            $taskCheckpoints=0
            $taskSummary=$taskText
            if ($Expected -eq 'spin mock OK' -and $taskText -match '^spin mock OK\r?\nspin checkpoints (\d+)$') {
                $taskCheckpoints=[int]$Matches[1]
                $taskSummary=$Expected
            }
            if ($taskProcess.ExitCode -ne 0 -or $taskSummary -ne $Expected) {
                throw "Large fixture failed: $Path`n$taskText`n$taskDiagnostics"
            }
            [pscustomobject]@{fixture=$Path;seconds=$taskWatch.Elapsed.TotalSeconds;checkpoints=$taskCheckpoints;output=$taskSummary}
        } finally { $taskProcess.Dispose() }
    }
    $taskGeneration=Invoke-LargeFixture $Lua 'tests/test_large.lua' 60 'Large script generation OK'
    Write-Output $taskGeneration.output
    $taskResults=@()
    foreach ($taskVariant in @('native','max','cooperative')) {
        $taskResult=Invoke-LargeFixture $Luau "tests/.generated/spin_large_${taskVariant}_mock.luau" 30 'spin mock OK'
        $taskResults+=$taskResult
        Write-Output ("Large Spin {0} OK ({1:F3}s, {2} startup checkpoints)" -f $taskVariant,$taskResult.seconds,$taskResult.checkpoints)
    }
    $taskResults | ConvertTo-Json | Set-Content -LiteralPath 'tests/.generated/spin_large_timings.json' -Encoding UTF8
    Write-Output 'All large script checks passed'
} finally { Pop-Location }
