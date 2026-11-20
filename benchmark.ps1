param([string]$Lua='lua', [string]$Luau='luau', [int]$Iterations=1500, [int]$Runs=3, [switch]$CompareGuards)
$ErrorActionPreference='Stop'
if ($Iterations -lt 1 -or $Runs -lt 1) { throw 'Iterations and Runs must be positive' }
$taskRoot=Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $taskRoot
try {
    $taskDirectory=Join-Path $taskRoot 'tests/.generated/benchmark'
    New-Item -ItemType Directory -Force -Path $taskDirectory | Out-Null
    $taskSource=@'
local function increment(value) return value+3 end
local checksum=0
local started=os.clock()
for i=1,ITERATIONS do
    checksum+=increment(i)
end
print(checksum,os.clock()-started)
'@
    $taskSource=$taskSource.Replace('ITERATIONS',[string]$Iterations)
    $taskInput=Join-Path $taskDirectory 'native.luau'
    [System.IO.File]::WriteAllText($taskInput,$taskSource)
    $taskVariants=@(
        @{Name='native'; Path=$taskInput; Arguments=@()},
        @{Name='fast'; Path=(Join-Path $taskDirectory 'fast.luau'); Arguments=@('--profile','fast')},
        @{Name='balanced'; Path=(Join-Path $taskDirectory 'balanced.luau'); Arguments=@('--profile','balanced')},
        @{Name='max'; Path=(Join-Path $taskDirectory 'max.luau'); Arguments=@('--profile','max')}
    )
    if ($CompareGuards) {
        foreach ($taskGuardVariant in @(
            @{Name='fast_tamper'; Profile='fast'; Arguments=@('--anti-tamper')},
            @{Name='fast_hooks'; Profile='fast'; Arguments=@('--anti-hooks','identity')},
            @{Name='fast_guards'; Profile='fast'; Arguments=@('--anti-tamper','--anti-hooks','identity')},
            @{Name='max_single'; Profile='max'; Arguments=@('--no-main')},
            @{Name='balanced_no_guards'; Profile='balanced'; Arguments=@('--no-anti-tamper','--no-anti-hooks')},
            @{Name='balanced_tamper'; Profile='balanced'; Arguments=@('--anti-tamper','--no-anti-hooks')},
            @{Name='balanced_hooks'; Profile='balanced'; Arguments=@('--no-anti-tamper','--anti-hooks','identity')}
        )) {
            $taskVariants+=@{Name=$taskGuardVariant.Name;
                Path=(Join-Path $taskDirectory ($taskGuardVariant.Name+'.luau'));
                Arguments=(@('--profile',$taskGuardVariant.Profile)+$taskGuardVariant.Arguments)}
        }
    }
    $taskExpected=$Iterations*($Iterations+1)/2+3*$Iterations
    foreach ($taskVariant in $taskVariants) {
        $taskBuildMilliseconds=0.0
        if ($taskVariant.Name -ne 'native') {
            $taskBuild=[System.Diagnostics.Stopwatch]::StartNew()
            $taskArguments=$taskVariant.Arguments
            & $Lua 'obfuscate.lua' $taskInput '-o' $taskVariant.Path '--force' '--seed' '12345' @taskArguments | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Build failed: $($taskVariant.Name)" }
            $taskBuild.Stop()
            $taskBuildMilliseconds=$taskBuild.Elapsed.TotalMilliseconds
        }
        $taskWallTimes=@()
        $taskLoopTimes=@()
        for ($taskRun=0; $taskRun -lt $Runs; $taskRun++) {
            $taskWatch=[System.Diagnostics.Stopwatch]::StartNew()
            $taskOutput=(& $Luau $taskVariant.Path 2>&1 | Out-String).Trim()
            $taskWatch.Stop()
            if ($LASTEXITCODE -ne 0) { throw "Execution failed: $($taskVariant.Name)`n$taskOutput" }
            $taskColumns=$taskOutput -split '\s+'
            if ($taskColumns.Count -ne 2 -or [double]$taskColumns[0] -ne $taskExpected) { throw "Checksum mismatch: $taskOutput" }
            $taskWallTimes+=$taskWatch.Elapsed.TotalMilliseconds
            $taskLoopTimes+=[double]::Parse($taskColumns[1],[System.Globalization.CultureInfo]::InvariantCulture)*1000
        }
        [pscustomobject]@{
            Profile=$taskVariant.Name
            Bytes=(Get-Item -LiteralPath $taskVariant.Path).Length
            BuildMs=[math]::Round($taskBuildMilliseconds,2)
            ProcessMs=[math]::Round(($taskWallTimes | Measure-Object -Average).Average,2)
            LoopMs=[math]::Round(($taskLoopTimes | Measure-Object -Average).Average,2)
            Iterations=$Iterations
            Runs=$Runs
        }
    }
} finally { Pop-Location }
