<#
.SYNOPSIS
    Full LOCAL regression: repository gates + POC-1..POC-5, with raw evidence logs.
.DESCRIPTION
    1. terraform fmt -check -recursive, terraform validate (bootstrap/account-a/account-b)
    2. POC-1..POC-5 run one after another (never concurrently). The RAW output of each
       POC is written to tests/evidence/local/pocN-latest.log BEFORE it is interpreted.
    3. Each log is scanned with a case-sensitive failure matcher:
           \[FAIL\] | \sFAIL\s*$ | Could not fully remove | ^\s*ERROR:
       Every matched line is printed with its log line number. Expected "Error:" lines
       from negative tests are counted separately and are NOT failures.
    4. TEMP gate: POC workspace folders (task<N>-poc-*) are snapshotted before and
       after each POC; only folders CREATED by that POC and still present count.
       Unrelated %TEMP% content is ignored.
    5. validate-local.ps1 (structure / hygiene) and git diff --check.

    Exit code 0 only if every gate passes. No AWS calls, nothing deployed.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\run-regression.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\run-regression.ps1 -Pocs 3
#>
[CmdletBinding()]
param(
    [int[]]$Pocs = @(1, 2, 3, 4, 5)
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$evidenceDir = Join-Path $repoRoot 'tests\evidence\local'
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

$failPattern = '\[FAIL\]|\sFAIL\s*$|Could not fully remove|^\s*ERROR: '
$expectedErrorPattern = '^\s*Error: '
$workspacePattern = '^task\d-poc-'
$gates = [ordered]@{}
$allPassed = $true

function Get-PocWorkspaces {
    return @(Get-ChildItem $env:TEMP -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $workspacePattern } | ForEach-Object { $_.FullName })
}

function Set-Gate {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    $script:gates[$Name] = @{ Passed = $Passed; Detail = $Detail }
    if (-not $Passed) { $script:allPassed = $false }
}

Push-Location $repoRoot
try {
    Write-Host "==> Repository gates" -ForegroundColor Cyan
    & terraform fmt -check -recursive | Out-Null
    Set-Gate 'terraform fmt -check -recursive' ($LASTEXITCODE -eq 0)
    foreach ($stack in @('bootstrap', 'account-a', 'account-b')) {
        & terraform "-chdir=$stack" init -backend=false -input=false -no-color *>&1 | Out-Null
        $v = (& terraform "-chdir=$stack" validate -no-color *>&1 | Out-String)
        Set-Gate "terraform validate $stack" ($LASTEXITCODE -eq 0 -and $v -match 'Success')
    }

    $leftoverTotal = @()
    foreach ($n in $Pocs) {
        $script = Join-Path $PSScriptRoot "task$n-local-poc.ps1"
        $log = Join-Path $evidenceDir "poc$n-latest.log"
        Write-Host "==> POC-$n  (raw log: tests\evidence\local\poc$n-latest.log)" -ForegroundColor Cyan

        $before = Get-PocWorkspaces
        $started = Get-Date
        $raw = (& powershell -NoProfile -ExecutionPolicy Bypass -File $script *>&1 | Out-String)
        $exit = $LASTEXITCODE
        $after = Get-PocWorkspaces
        $created = @($after | Where-Object { $before -notcontains $_ })

        # Raw evidence first, interpretation second.
        $header = "# POC-$n raw output`n# started : $($started.ToString('yyyy-MM-dd HH:mm:ss'))`n# script  : scripts/task$n-local-poc.ps1`n# exit    : $exit`n"
        [System.IO.File]::WriteAllText($log, $header + $raw, (New-Object System.Text.UTF8Encoding($false)))

        $lines = $raw -split "`r?`n"
        $matched = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            # The log header is 4 lines, so raw line index 0 is log line 5.
            if ($lines[$i] -cmatch $failPattern) { $matched += ('{0,5}: {1}' -f ($i + 5), $lines[$i].TrimEnd()) }
        }
        $expectedErrors = @($lines | Where-Object { $_ -cmatch $expectedErrorPattern }).Count
        $summary = (($lines | Where-Object { $_ -match "POC-$n \(LOCAL\)" }) -join ' ').Trim()

        $pocOk = ($exit -eq 0) -and ($matched.Count -eq 0) -and ($created.Count -eq 0) -and ($summary -match 'PASS')
        $detail = "exit=$exit realFails=$($matched.Count) expectedNegativeTestErrorLines=$expectedErrors newTempWorkspacesLeft=$($created.Count)"
        Set-Gate "POC-$n" $pocOk $detail
        Write-Host "    $detail"
        Write-Host "    $summary"
        if ($matched.Count -gt 0) {
            Write-Host "    Matched failure lines (log line numbers):" -ForegroundColor Red
            $matched | ForEach-Object { Write-Host "    >> $_" -ForegroundColor Red }
            Write-Host "    Raw evidence: $log" -ForegroundColor Red
        }
        if ($created.Count -gt 0) {
            Write-Host "    TEMP workspaces left by POC-$n (preserved for diagnosis):" -ForegroundColor Red
            $created | ForEach-Object { Write-Host "    >> $_" -ForegroundColor Red }
            $leftoverTotal += $created
        }
    }
    Set-Gate 'Raw logs captured' (@($Pocs | Where-Object { -not (Test-Path (Join-Path $evidenceDir "poc$_-latest.log")) }).Count -eq 0)
    Set-Gate 'New TEMP workspaces remaining = 0' ($leftoverTotal.Count -eq 0) "($($leftoverTotal.Count))"

    Write-Host "==> validate-local / hygiene" -ForegroundColor Cyan
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'validate-local.ps1') *>&1 | Out-Null
    Set-Gate 'validate-local / hygiene' ($LASTEXITCODE -eq 0)

    & git diff --check | Out-Null
    Set-Gate 'git diff --check' ($LASTEXITCODE -eq 0)
}
finally {
    Pop-Location
}

Write-Host ''
Write-Host '==================== LOCAL REGRESSION SUMMARY ====================' -ForegroundColor Cyan
foreach ($name in $gates.Keys) {
    $g = $gates[$name]
    $label = 'FAIL'
    $color = 'Red'
    if ($g.Passed) {
        $label = 'PASS'
        $color = 'Green'
    }
    Write-Host ('{0,-40} {1}  {2}' -f $name, $label, $g.Detail) -ForegroundColor $color
}
Write-Host ''
Write-Host 'REAL AWS POCs                            PENDING' -ForegroundColor Yellow
if ($allPassed) {
    Write-Host 'LOCAL REGRESSION: PASS' -ForegroundColor Green
    exit 0
}
Write-Host 'LOCAL REGRESSION: FAIL' -ForegroundColor Red
exit 1
