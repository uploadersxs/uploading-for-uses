param([string]$Lua = 'lua', [string]$Luau = 'luau')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $taskRoot
try {
    $taskFolder = Join-Path $taskRoot 'tests/.generated/cli'
    New-Item -ItemType Directory -Force -Path $taskFolder | Out-Null
    function Invoke-Verity([string[]]$Arguments, [bool]$ShouldFail = $false) {
        $taskOldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $taskText = (& $Lua 'obfuscate.lua' @Arguments 2>&1 | Out-String)
        $taskExit = $LASTEXITCODE
        $ErrorActionPreference = $taskOldPreference
        if ($ShouldFail -and $taskExit -eq 0) { throw "CLI unexpectedly succeeded: $Arguments" }
        if (-not $ShouldFail -and $taskExit -ne 0) { throw "CLI failed: $taskText" }
        return $taskText
    }
    $taskInput = Join-Path $taskFolder 'input.luau'
    $taskOutput = Join-Path $taskFolder 'output.luau'
    $taskStats = Join-Path $taskFolder 'stats.json'
    [IO.File]::WriteAllText($taskInput, 'assert(6*7==42); print("cli OK")', [Text.UTF8Encoding]::new($false))
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--profile', 'fast', '--seed', '12345', '--stats', $taskStats, '--force') | Out-Null
    $taskParsed = Get-Content -LiteralPath $taskStats -Raw | ConvertFrom-Json
    if ($taskParsed.profile -ne 'fast' -or $taskParsed.mainPacked -or [Math]::Abs([double]$taskParsed.settings.junk - 0.05) -gt 1e-12) { throw 'Fast profile settings failed' }
    if ($taskParsed.settings.antiTamper -or $taskParsed.settings.antiHooks -ne 'off' -or $taskParsed.settings.antiBeautify) { throw 'Fast guard defaults failed' }
    if ($null -eq $taskParsed.timings.total -or $null -eq $taskParsed.timings.compile) { throw 'Phase timings missing' }
    $taskActual = (& $Luau $taskOutput 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $taskActual -ne 'cli OK') { throw "CLI runtime failed: $taskActual" }
    $taskProtected = [IO.File]::ReadAllText($taskOutput)
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--profile', 'fast', '--seed', '12345', '--force') | Out-Null
    if ([IO.File]::ReadAllText($taskOutput) -ne $taskProtected) { throw 'CLI output not deterministic' }
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--seed', '1') $true | Out-Null
    if ([IO.File]::ReadAllText($taskOutput) -ne $taskProtected) { throw 'Rejected overwrite changed output' }
    [IO.File]::WriteAllText($taskInput, 'local = 1', [Text.UTF8Encoding]::new($false))
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--force') $true | Out-Null
    if ([IO.File]::ReadAllText($taskOutput) -ne $taskProtected) { throw 'Failed compilation changed existing output' }
    [IO.File]::WriteAllText($taskInput, 'print("cli OK")', [Text.UTF8Encoding]::new($false))
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--profile', 'max', '--junk', '0', '--no-main', '--seed', '1', '--stats', $taskStats, '--force') | Out-Null
    $taskParsed = Get-Content -LiteralPath $taskStats -Raw | ConvertFrom-Json
    if ($taskParsed.profile -ne 'max' -or $taskParsed.mainPacked -or $taskParsed.settings.junk -ne 0) { throw 'Explicit profile overrides failed' }
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--profile', 'max', '--seed', '12345', '--stats', $taskStats, '--force') | Out-Null
    $taskParsed = Get-Content -LiteralPath $taskStats -Raw | ConvertFrom-Json
    if (-not $taskParsed.mainPacked -or -not $taskParsed.settings.nativeHelpers -or $taskParsed.nativeHelpers -le 0 -or -not $taskParsed.settings.cooperative -or $taskParsed.settings.yieldBudgetMs -ne 8) { throw 'Packed profile acceleration defaults failed' }
    $taskActual = (& $Luau $taskOutput 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $taskActual -ne 'cli OK') { throw "Accelerated CLI runtime failed: $taskActual" }
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--no-native-helpers', '--no-cooperative', '--yield-budget-ms', '3.5', '--profile', 'max', '--seed', '12345', '--stats', $taskStats, '--force') | Out-Null
    $taskParsed = Get-Content -LiteralPath $taskStats -Raw | ConvertFrom-Json
    if (-not $taskParsed.mainPacked -or $taskParsed.settings.nativeHelpers -or $taskParsed.nativeHelpers -ne 0 -or $taskParsed.settings.cooperative -or $taskParsed.settings.yieldBudgetMs -ne 3.5) { throw 'Legacy byte-work and scheduler CLI overrides failed' }
    $taskActual = (& $Luau $taskOutput 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $taskActual -ne 'cli OK') { throw "Legacy CLI runtime failed: $taskActual" }
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--profile', 'fast', '--cooperative', '--yield-budget-ms', '2', '--seed', '12345', '--stats', $taskStats, '--force') | Out-Null
    $taskParsed = Get-Content -LiteralPath $taskStats -Raw | ConvertFrom-Json
    if ($taskParsed.mainPacked -or $taskParsed.settings.nativeHelpers -or $taskParsed.nativeHelpers -ne 0 -or -not $taskParsed.settings.cooperative -or $taskParsed.settings.yieldBudgetMs -ne 2) { throw 'Single-layer cooperative CLI enable failed' }
    $taskActual = (& $Luau $taskOutput 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $taskActual -ne 'cli OK') { throw "Cooperative CLI runtime failed: $taskActual" }
    $taskSchedulingProtected = [IO.File]::ReadAllText($taskOutput)
    foreach ($taskInvalidBudget in @('0','-1','1001','invalid','1e309')) {
        Invoke-Verity @($taskInput, '-o', $taskOutput, '--profile', 'max', '--yield-budget-ms', $taskInvalidBudget, '--force') $true | Out-Null
        if ([IO.File]::ReadAllText($taskOutput) -ne $taskSchedulingProtected) { throw 'Rejected scheduler budget changed output' }
    }
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--constant-cache', 'invalid', '--force') $true | Out-Null
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--profile', 'invalid', '--force') $true | Out-Null
    $taskMap = Join-Path $taskFolder 'map.json'
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--profile', 'fast', '--map', $taskMap, '--seed', '1', '--force') | Out-Null
    $taskParsedMap = Get-Content -LiteralPath $taskMap -Raw | ConvertFrom-Json
    if ($null -eq $taskParsedMap) { throw 'Source map JSON missing' }
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--profile', 'balanced', '--no-main', '--seed', '12345', '--stats', $taskStats, '--force') | Out-Null
    $taskParsed = Get-Content -LiteralPath $taskStats -Raw | ConvertFrom-Json
    if (-not $taskParsed.settings.antiTamper -or $taskParsed.settings.antiHooks -ne 'identity' -or $taskParsed.settings.antiBeautify) { throw 'Balanced guard defaults failed' }
    Invoke-Verity @('--anti-hooks', $taskInput, '-o', $taskOutput, '--profile', 'fast', '--anti-tamper', '--seed', '12345', '--stats', $taskStats, '--force') | Out-Null
    $taskParsed = Get-Content -LiteralPath $taskStats -Raw | ConvertFrom-Json
    if (-not $taskParsed.settings.antiTamper -or $taskParsed.settings.antiHooks -ne 'identity') { throw 'Explicit guard enable or optional hook mode failed' }
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--profile', 'fast', '--anti-hooks=strict', '--seed', '12345', '--stats', $taskStats, '--force') | Out-Null
    $taskParsed = Get-Content -LiteralPath $taskStats -Raw | ConvertFrom-Json
    if ($taskParsed.settings.antiHooks -ne 'strict') { throw 'Strict CLI hook mode failed' }
    $taskActual = (& $Luau $taskOutput 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $taskActual -ne 'cli OK') { throw "Strict CLI runtime failed: $taskActual" }
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--profile', 'max', '--no-main', '--no-anti-tamper', '--no-anti-hooks', '--no-anti-beautify', '--seed', '12345', '--stats', $taskStats, '--force') | Out-Null
    $taskParsed = Get-Content -LiteralPath $taskStats -Raw | ConvertFrom-Json
    if ($taskParsed.settings.antiTamper -or $taskParsed.settings.antiHooks -ne 'off' -or $taskParsed.settings.antiBeautify) { throw 'Explicit guard disable failed' }
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--profile', 'fast', '--anti-beautify', '--seed', '12345', '--stats', $taskStats, '--force') | Out-Null
    $taskParsed = Get-Content -LiteralPath $taskStats -Raw | ConvertFrom-Json
    if (-not $taskParsed.settings.antiBeautify) { throw 'Anti-beautify CLI setting failed' }
    $taskActual = (& $Luau $taskOutput 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $taskActual -ne 'cli OK') { throw "Anti-beautify CLI runtime failed: $taskActual" }
    $taskGuardProtected = [IO.File]::ReadAllText($taskOutput)
    foreach ($taskConflict in @('--readable','--debug')) {
        Invoke-Verity @($taskInput, '-o', $taskOutput, '--anti-beautify', $taskConflict, '--force') $true | Out-Null
        if ([IO.File]::ReadAllText($taskOutput) -ne $taskGuardProtected) { throw 'Rejected guard combination changed output' }
    }
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--anti-beautify', '--map', $taskMap, '--force') $true | Out-Null
    Invoke-Verity @($taskInput, '-o', $taskOutput, '--anti-hooks=invalid', '--force') $true | Out-Null
    # Shell metacharacters remain literal filesystem characters during enumeration and writes.
    $taskBatch = Join-Path $taskFolder 'batch space '' & % ! $()'
    $taskDestination = Join-Path $taskBatch 'protected'
    New-Item -ItemType Directory -Force -Path (Join-Path $taskBatch 'nested') | Out-Null
    [IO.File]::WriteAllText((Join-Path $taskBatch 'a.luau'), 'print("batch A")', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $taskBatch 'nested/b.lua'), 'print("batch B")', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $taskBatch 'ignored.obf.luau'), 'local = 1', [Text.UTF8Encoding]::new($false))
    Invoke-Verity @('--batch', $taskBatch, '--out-dir', $taskDestination, '--profile', 'fast', '--seed', '1', '--stats', $taskStats, '--force') | Out-Null
    $taskBatchStats = Get-Content -LiteralPath $taskStats -Raw | ConvertFrom-Json
    if ($taskBatchStats.files.Count -ne 2) { throw 'Batch enumeration included generated output or missed a source' }
    if (-not (Test-Path -LiteralPath (Join-Path $taskDestination 'nested/b.obf.luau'))) { throw 'Batch subdirectories not preserved' }
    Invoke-Verity @('--batch', $taskBatch, '--out-dir', $taskDestination, '--profile', 'fast', '--seed', '1', '--stats', $taskStats, '--force') | Out-Null
    $taskBatchStats = Get-Content -LiteralPath $taskStats -Raw | ConvertFrom-Json
    if ($taskBatchStats.files.Count -ne 2) { throw 'Batch destination tree was reprocessed' }
    Write-Output 'CLI checks OK'
} finally { Pop-Location }
