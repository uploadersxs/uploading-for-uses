param([string]$Lua = 'lua', [string]$Luau = 'luau')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $taskRoot
try {
    New-Item -ItemType Directory -Force -Path 'tests/.generated' | Out-Null
    & $Lua 'tests/test_parser.lua'
    if ($LASTEXITCODE -ne 0) { throw 'Parser checks failed' }
    if (Test-Path -LiteralPath 'tests/test_optimizer.lua') {
        & $Lua 'tests/test_optimizer.lua'
        if ($LASTEXITCODE -ne 0) { throw 'Optimizer checks failed' }
    }
    & $Lua 'tests/test_host.lua'
    if ($LASTEXITCODE -ne 0) { throw 'Host checks failed' }
    & $Lua 'tests/test_guards.lua'
    if ($LASTEXITCODE -ne 0) { throw 'Guard host checks failed' }
    & $Lua 'tests/test_security.lua'
    if ($LASTEXITCODE -ne 0) { throw 'Security host checks failed' }
    & $Lua 'tests/test_scheduler.lua'
    if ($LASTEXITCODE -ne 0) { throw 'Scheduler host checks failed' }
    $taskScheduler=(& $Luau 'tests/.generated/scheduler.luau' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $taskScheduler -ne 'scheduler OK') { throw "Scheduler runtime checks failed`n$taskScheduler" }
    & $Luau 'tests/.generated/scheduler_binding.luau'
    if ($LASTEXITCODE -ne 0) { throw 'Scheduler binding checks failed' }
    & $Lua 'tests/test_fixed_results.lua'
    if ($LASTEXITCODE -ne 0) { throw 'Fixed-result host checks failed' }
    foreach ($taskFixed in @('native','fast','balanced','max','invalid')) {
        $taskFixedText=(& $Luau "tests/.generated/fixed_results_$taskFixed.luau" 2>&1 | Out-String).Trim()
        $taskFixedExpected=if ($taskFixed -eq 'invalid') { 'fixed results invalid OK' } else { 'fixed results OK' }
        if ($LASTEXITCODE -ne 0 -or $taskFixedText -ne $taskFixedExpected) { throw "Fixed-result fixture failed: $taskFixed`n$taskFixedText" }
    }
    & $Lua 'tests/test_guard_tuple.lua'
    if ($LASTEXITCODE -ne 0) { throw 'Tuple-guard host checks failed' }
    foreach ($taskTuple in @('trusted','untrusted','invalid_arity','invalid_range')) {
        $taskTupleText=(& $Luau "tests/.generated/guard_tuple_$taskTuple.luau" 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $taskTupleText -ne "guard tuple $($taskTuple.Replace('_',' ')) OK") { throw "Tuple-guard fixture failed: $taskTuple`n$taskTupleText" }
    }
    & $Lua 'tests/test_fetch.lua'
    if ($LASTEXITCODE -ne 0) { throw 'Fetch host checks failed' }
    & $Luau 'tests/.generated/fetch.luau'
    if ($LASTEXITCODE -ne 0) { throw 'Fetch runtime checks failed' }
    foreach ($taskName in @('core', 'loops', 'luau', 'runtime', 'evaluation', 'numbers', 'advanced', 'interpolation', 'types', 'minify', 'optimizer')) {
        $taskExpected = (& $Luau "tests/fixtures/$taskName.luau" 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "Native fixture failed: $taskName`n$taskExpected" }
        foreach ($taskSeed in @(1,12345,2147483646)) {
            $taskActual = (& $Luau "tests/.generated/${taskName}_${taskSeed}.luau" 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { throw "VM fixture failed: $taskName seed $taskSeed`n$taskActual" }
            if ($taskActual -ne $taskExpected) { throw "Output mismatch: $taskName seed $taskSeed" }
            Write-Output "$taskName seed $taskSeed OK"
        }
    }
    $taskPlain = (& $Luau 'tests/.generated/core_plain.luau' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $taskPlain -ne 'core OK') { throw "VM without passes failed`n$taskPlain" }
    $taskCompact = (& $Luau 'tests/.generated/minify_compact.luau' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $taskCompact -ne 'minify OK') { throw 'Direct minifier execution failed' }
    $taskLiteral = (& $Luau 'tests/.generated/literal.luau' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $taskLiteral -ne 'literal OK') { throw 'Literal transport execution failed' }
    $taskArgs = (& $Luau 'tests/.generated/main_args.luau' '-a' 'alpha' 'beta' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $taskArgs -ne 'args OK') { throw 'Main envelope caller arguments failed' }
    $ErrorActionPreference = 'Continue'
    $taskError = (& $Luau 'tests/.generated/corrupt.luau' 2>&1 | Out-String)
    $taskCorruptExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($taskCorruptExit -eq 0) { throw 'Corrupt payload was not rejected correctly' }
    if ($taskError -match 'OVM:') { throw 'Runtime diagnostics leaked in emitted code' }
    if (Test-Path -LiteralPath 'tests/.generated/locale.luau') {
        $taskLocale = (& $Luau 'tests/.generated/locale.luau' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $taskLocale -ne 'locale OK') { throw 'Numeric locale portability failed' }
    }
    $taskInput = 'tests/.generated/alias_input.luau'
    $taskSource = 'print("preserved")'
    [System.IO.File]::WriteAllText((Join-Path $taskRoot $taskInput), $taskSource)
    $ErrorActionPreference = 'Continue'
    $taskAliasOutput = (& $Lua 'obfuscate.lua' $taskInput '-o' 'tests/.generated/../.generated/alias_input.luau' '--seed' '1' 2>&1 | Out-String)
    $taskAliasExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($taskAliasExit -eq 0 -or $taskAliasOutput -notmatch 'output must differ from input') { throw 'Source alias was not rejected' }
    if ([System.IO.File]::ReadAllText((Join-Path $taskRoot $taskInput)) -ne $taskSource) { throw 'Source was modified by rejected CLI call' }
    & $Lua 'tests/test_differential.lua'
    if ($LASTEXITCODE -ne 0) { throw 'Differential input generation failed' }
    for ($taskCase=1; $taskCase -le 6; $taskCase++) {
        $taskExpected=(& $Luau "tests/.generated/diff_${taskCase}_native.luau" 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "Native differential case failed: $taskCase`n$taskExpected" }
        foreach ($taskProfile in @('fast','balanced','max')) {
            $taskActual=(& $Luau "tests/.generated/diff_${taskCase}_${taskProfile}.luau" 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0 -or $taskActual -ne $taskExpected) { throw "Differential mismatch: $taskCase $taskProfile`n$taskActual" }
        }
        Write-Output "Differential case $taskCase OK"
    }
    $taskExpected=(& $Luau 'tests/fixtures/lazy.luau' 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Native lazy fixture failed`n$taskExpected" }
    foreach ($taskVariant in @('fast','balanced','max','legacy','eager','execution','none','unoptimized','debug')) {
        $taskActual=(& $Luau "tests/.generated/lazy_${taskVariant}.luau" 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $taskActual -ne $taskExpected) { throw "Lazy fixture mismatch: $taskVariant`n$taskActual" }
        Write-Output "Lazy $taskVariant OK"
    }
    foreach ($taskMode in @('prototype','execution','none')) {
        $taskActual=(& $Luau "tests/.generated/materialization_${taskMode}.luau" 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $taskActual -ne "materialization $taskMode OK") { throw "Lazy materialization failed: $taskMode`n$taskActual" }
        Write-Output $taskActual
    }
    foreach ($taskTrace in @('single','main')) {
        $taskActual=(& $Luau "tests/.generated/trace_${taskTrace}.luau" 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $taskActual -ne "trace $taskTrace OK") { throw "Debug trace failed: $taskTrace`n$taskActual" }
        Write-Output $taskActual
    }
    foreach ($taskWire in @('compact_lazy','fixed_lazy','compact_eager','width_3','width_300','width_70000')) {
        $taskActual=(& $Luau "tests/.generated/wire_${taskWire}.luau" 2>&1 | Out-String).Trim()
        $taskLabel=if ($taskWire.StartsWith('width_')) { $taskWire.Replace('_',' ') } else { $taskWire }
        if ($LASTEXITCODE -ne 0 -or $taskActual -ne "wire $taskLabel OK") { throw "Wire fixture failed: $taskWire`n$taskActual" }
        Write-Output $taskActual
    }
    for ($taskCase=1; $taskCase -le 5; $taskCase++) {
        $ErrorActionPreference='Continue'
        $taskInvalid=(& $Luau "tests/.generated/syntax_invalid_${taskCase}.luau" 2>&1 | Out-String)
        $taskInvalidExit=$LASTEXITCODE
        $ErrorActionPreference='Stop'
        if ($taskInvalidExit -eq 0) { throw "Native Luau unexpectedly accepted invalid differential case: $taskCase" }
    }
    $taskGuardExpected=(& $Luau 'tests/fixtures/guards.luau' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Native guard fixture failed`n$taskGuardExpected" }
    foreach ($taskGuardVariant in @('single','main','strict_single','strict_main')) {
        $taskActual=(& $Luau "tests/.generated/guards_normal_${taskGuardVariant}.luau" 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $taskActual -ne $taskGuardExpected) { throw "Guarded normal execution failed: $taskGuardVariant`n$taskActual" }
        Write-Output "Guards normal $taskGuardVariant OK"
    }
    $taskGuardCases=@('prehook_identity','prehook_strict','missing_debug_identity','missing_debug_strict',
        'tamper_loaded','tamper_after_call','metadata_frozen','metadata_no_probe',
        'freeze_capture_lazy','freeze_capture_eager','holes_identity','holes_strict')
    foreach ($taskGuardMetamethod in @('un_alias','tostring_alias','index_alias','index_detach',
        'newindex_detach','global_index_detach','global_newindex_detach')) {
        foreach ($taskGuardMode in @('identity','off')) { $taskGuardCases+="meta_${taskGuardMetamethod}_${taskGuardMode}" }
    }
    foreach ($taskGuardLayer in @('single','main')) {
        foreach ($taskGuardMode in @('identity','off')) {
            foreach ($taskGuardSite in @('call','frame','yield')) {
                $taskGuardCases+="${taskGuardSite}_${taskGuardLayer}_${taskGuardMode}"
            }
        }
        $taskGuardCases+="beautify_${taskGuardLayer}"
        $taskGuardCases+="formatting_${taskGuardLayer}"
    }
    foreach ($taskGuardCase in $taskGuardCases) {
        $taskActual=(& $Luau "tests/.generated/guards_${taskGuardCase}.luau" 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $taskActual -ne "guards $taskGuardCase OK") { throw "Guard case failed: $taskGuardCase`n$taskActual" }
        Write-Output $taskActual
    }
    foreach ($taskGuardLayer in @('single','main')) {
        foreach ($taskGuardRejection in @('edited','missing_debug')) {
            $ErrorActionPreference='Continue'
            $taskActual=(& $Luau "tests/.generated/guards_beautify_${taskGuardLayer}_${taskGuardRejection}.luau" 2>&1 | Out-String)
            $taskGuardExit=$LASTEXITCODE
            $ErrorActionPreference='Stop'
            if ($taskGuardExit -eq 0 -or $taskActual.Contains("guards beautify_$taskGuardLayer OK")) {
                throw "Anti-beautify rejection escaped: $taskGuardLayer $taskGuardRejection"
            }
            Write-Output "Guards beautify $taskGuardLayer $taskGuardRejection rejected OK"
        }
    }
    # Run mutation cases in separate processes with a deadline. The transport
    # checksum is rebuilt by the generator, so malformed bytes reach the loader.
    foreach ($taskSecurityCase in (Get-Content -LiteralPath 'tests/.generated/security_manifest.txt')) {
        $taskSecurityPath=(Resolve-Path -LiteralPath "tests/.generated/security_${taskSecurityCase}.luau").ProviderPath
        $taskSecurityStart=[System.Diagnostics.ProcessStartInfo]::new()
        $taskSecurityStart.FileName=(Get-Command $Luau -ErrorAction Stop).Source
        $taskSecurityStart.Arguments='"'+$taskSecurityPath+'"'
        $taskSecurityStart.UseShellExecute=$false
        $taskSecurityStart.CreateNoWindow=$true
        $taskSecurityStart.RedirectStandardOutput=$true
        $taskSecurityStart.RedirectStandardError=$true
        $taskSecurityProcess=[System.Diagnostics.Process]::new()
        $taskSecurityProcess.StartInfo=$taskSecurityStart
        try {
            if (-not $taskSecurityProcess.Start()) { throw "Security process did not start: $taskSecurityCase" }
            $taskSecurityOutput=$taskSecurityProcess.StandardOutput.ReadToEndAsync()
            $taskSecurityError=$taskSecurityProcess.StandardError.ReadToEndAsync()
            if (-not $taskSecurityProcess.WaitForExit(15000)) {
                try { $taskSecurityProcess.Kill($true) } catch { $taskSecurityProcess.Kill() }
                throw "Security fixture timed out: $taskSecurityCase"
            }
            $taskSecurityText=$taskSecurityOutput.GetAwaiter().GetResult().Trim()
            $taskSecurityDiagnostics=$taskSecurityError.GetAwaiter().GetResult()
            if ($taskSecurityProcess.ExitCode -ne 0 -or $taskSecurityText -ne "security $taskSecurityCase OK") {
                throw "Security fixture failed: $taskSecurityCase`n$taskSecurityText`n$taskSecurityDiagnostics"
            }
            Write-Output $taskSecurityText
        } finally { $taskSecurityProcess.Dispose() }
    }
    if (Test-Path -LiteralPath 'tests/test_cli.ps1') {
        & "$PSScriptRoot/test_cli.ps1" -Lua $Lua -Luau $Luau
    }
    if (Test-Path -LiteralPath 'tests/test_acceleration.ps1') {
        & "$PSScriptRoot/test_acceleration.ps1" -Lua $Lua -Luau $Luau
    }
    & "$PSScriptRoot/test_large.ps1" -Lua $Lua -Luau $Luau
    Write-Output 'All VM checks passed'
} finally { Pop-Location }
