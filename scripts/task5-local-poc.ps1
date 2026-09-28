<#
.SYNOPSIS
    Task 5 LOCAL POC - demonstrate the two original IAM bugs and prove the fixes.
.DESCRIPTION
    BUG 1: roleC trust names arn:aws:iam::000000000000:user/roleB (roleB is a ROLE).
    BUG 2: roleC permissions grant s3:* on Resource "*" (every bucket).

    1. Baseline          : scripts/validate-local.ps1
    2. Offline plans     : account-a (roleB) and account-b (roleC), TEMP copies,
                           mock credentials, zero AWS calls
    3. BUG 1             : broken fixture detected; roleB DENIED by it; roleB ALLOWED
                           by the fixed/deployed trust; exact role ARN used
    4. BUG 2             : broken fixture detected; it permits unrelated buckets; the
                           fixed/deployed policy allows the target bucket + objects
                           and denies unrelated buckets + objects
    5. Deployable code   : no user/roleB and no roleC Resource "*" in any .tf file or
                           rendered policy; no .tf file references the fixtures;
                           fixed fixtures == Terraform-rendered policies (no drift)

    Access decisions use the simplified IAM model (IamPolicyModel.psm1) - POC MODEL
    ONLY, not AWS. REAL AWS before/after tests: PENDING (tests/task5-test.md).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\task5-local-poc.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$results = [ordered]@{}
Import-Module (Join-Path $PSScriptRoot 'OfflineWorkspace.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'IamPolicyModel.psm1') -Force

$acctA = '000000000000'
$acctB = '111111111111'
$roleBArn = "arn:aws:iam::${acctA}:role/roleB"
$userRoleBArn = "arn:aws:iam::${acctA}:user/roleB"
$roleCArn = "arn:aws:iam::${acctB}:role/roleC"
$targetArn = 'arn:aws:s3:::aws-terraform-devops-assignment-crossacct-111111111111'
$otherArn = 'arn:aws:s3:::some-unrelated-bucket'
$fixtureDir = Join-Path $repoRoot 'tests\fixtures\task5'

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    $label = 'FAIL'
    $color = 'Red'
    if ($Passed) {
        $label = 'ok  '
        $color = 'Green'
    }
    Write-Host ("  [{0}] {1} {2}" -f $label, $Name, $Detail) -ForegroundColor $color
    return $Passed
}

function Join-Sorted {
    # Flatten, sort, join. Binary -join binds LOOSER than -eq, so compare the result.
    param($Value)
    if ($null -eq $Value) { return '' }
    $flat = @($Value | ForEach-Object { $_ })
    return (($flat | Sort-Object) -join ',')
}

function Get-NormalizedPolicy {
    # Order-independent canonical text (statements, principals, actions, resources, conditions).
    param($Doc)
    $lines = foreach ($s in @($Doc.Statement | ForEach-Object { $_ })) {
        $principal = ''
        if ($null -ne $s.Principal) { $principal = Join-Sorted $s.Principal.AWS }
        $cond = ''
        if ($null -ne $s.Condition) {
            $parts = foreach ($op in $s.Condition.PSObject.Properties) {
                foreach ($k in $op.Value.PSObject.Properties) { '{0}:{1}={2}' -f $op.Name, $k.Name, (Join-Sorted $k.Value) }
            }
            $cond = (@($parts) | Sort-Object) -join ';'
        }
        '{0}|{1}|P={2}|A={3}|R={4}|C={5}' -f $s.Sid, $s.Effect, $principal, (Join-Sorted $s.Action), (Join-Sorted $s.Resource), $cond
    }
    return ((@($lines) | Sort-Object) -join "`n")
}

function Get-Principals {
    param($Doc)
    return @($Doc.Statement | ForEach-Object { $_ } | ForEach-Object { $_.Principal.AWS } | ForEach-Object { $_ })
}

function Get-Resources {
    param($Doc)
    return @($Doc.Statement | ForEach-Object { $_ } | ForEach-Object { $_.Resource } | ForEach-Object { $_ })
}

function Get-Plan {
    param([string]$Stack, [string]$TempRoot, [string[]]$ExtraArgs = @())
    $ws = New-OfflineWorkspace -RepoRoot $repoRoot -Stack $Stack -Destination (Join-Path $TempRoot $Stack)
    $pluginDir = Get-RepoPluginDir -RepoRoot $repoRoot -Stack $Stack
    $r = Invoke-Terraform @("-chdir=$ws", 'init', '-backend=false', '-input=false', '-no-color', "-plugin-dir=$pluginDir")
    if ($r.Exit -ne 0) { return $null }
    $planFile = Join-Path $TempRoot "$Stack.tfplan"
    $r = Invoke-Terraform (@("-chdir=$ws", 'plan', '-refresh=false', '-input=false', '-no-color', "-out=$planFile") + $ExtraArgs)
    if ($r.Exit -ne 0) { Write-Host $r.Text -ForegroundColor Red; return $null }
    return (& terraform "-chdir=$ws" show -json $planFile | Out-String | ConvertFrom-Json)
}

function Get-RenderedDoc {
    param($Plan, [string]$Address, [string]$Attribute)
    $after = ($Plan.resource_changes | Where-Object { $_.address -eq $Address }).change.after
    return ($after.$Attribute | ConvertFrom-Json)
}

$tempRoot = Join-Path $env:TEMP ("task5-poc-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    # ------------------------------------------------------------------
    Write-Step '1. Baseline: validate-local.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'validate-local.ps1') -PocLabel 'BASELINE' *>&1 |
        Select-String -Pattern '^(Repository structure|Required files|terraform (fmt|init|validate)|Secret/state check|Git repository)\s|BASELINE|missing' |
        ForEach-Object { Write-Host "  $_" }
    $results['Baseline: repo fmt/init/validate/hygiene'] = ($LASTEXITCODE -eq 0)

    # ------------------------------------------------------------------
    Write-Step '2. Offline plans (TEMP copies, mock credentials, no AWS calls)'
    $planA = Get-Plan -Stack 'account-a' -TempRoot $tempRoot -ExtraArgs @('-var-file=terraform.tfvars.example')
    $planB = Get-Plan -Stack 'account-b' -TempRoot $tempRoot
    if (-not (Write-Check 'account-a and account-b offline plans' (($null -ne $planA) -and ($null -ne $planB)))) {
        throw 'Offline plan failed - cannot continue.'
    }
    $roleBPolicy = Get-RenderedDoc $planA 'aws_iam_role_policy.role_b' 'policy'
    $deployedTrust = Get-RenderedDoc $planB 'aws_iam_role.role_c' 'assume_role_policy'
    $deployedS3 = Get-RenderedDoc $planB 'aws_iam_role_policy.role_c' 'policy'

    $brokenTrust = Get-Content -Raw (Join-Path $fixtureDir 'broken-trust-policy.json') | ConvertFrom-Json
    $fixedTrust = Get-Content -Raw (Join-Path $fixtureDir 'fixed-trust-policy.json') | ConvertFrom-Json
    $brokenS3 = Get-Content -Raw (Join-Path $fixtureDir 'broken-s3-policy.json') | ConvertFrom-Json
    $fixedS3 = Get-Content -Raw (Join-Path $fixtureDir 'fixed-s3-policy.json') | ConvertFrom-Json

    # ------------------------------------------------------------------
    Write-Step 'BUG 1 - wrong principal type (user/roleB instead of role/roleB)'
    Write-Host "      BROKEN  $userRoleBArn" -ForegroundColor DarkGray
    Write-Host "      FIXED   $roleBArn" -ForegroundColor DarkGray
    # @() at the call site: a 1-element array returned from a function is unrolled
    # to a scalar string, and $x[0] would then be its first CHARACTER.
    $bp = @(Get-Principals $brokenTrust)
    $results['Broken trust fixture detected'] = (Write-Check 'broken fixture trusts a USER principal (:user/roleB)' (($bp.Count -eq 1) -and ($bp[0] -eq $userRoleBArn)) "($($bp -join ', '))")

    # roleB session calls AssumeRole on roleC. Identity side = the REAL rendered roleB policy.
    $brk = Test-AssumeRole -CallerArn $roleBArn -CallerPolicies @($roleBPolicy) -TargetRoleArn $roleCArn -TargetTrustPolicy $brokenTrust
    $results['Broken user/roleB principal rejects roleB'] = (Write-Check 'roleB -> AssumeRole roleC with BROKEN trust => DENIED' (-not $brk.Allowed) "(identity=$($brk.Identity), trust=$($brk.Trust))")

    $fixedOk = $true
    foreach ($pair in @(@('fixed fixture', $fixedTrust), @('deployed Terraform trust', $deployedTrust))) {
        $fx = Test-AssumeRole -CallerArn $roleBArn -CallerPolicies @($roleBPolicy) -TargetRoleArn $roleCArn -TargetTrustPolicy $pair[1]
        $fixedOk = (Write-Check "roleB -> AssumeRole roleC with $($pair[0]) => ALLOWED" $fx.Allowed "(identity=$($fx.Identity), trust=$($fx.Trust))") -and $fixedOk
    }
    $results['Fixed role/roleB principal permits roleB'] = $fixedOk

    $dp = @(Get-Principals $deployedTrust)
    $exact = ($dp.Count -eq 1) -and ($dp[0] -eq $roleBArn) -and ((Join-Sorted (Get-Principals $fixedTrust)) -eq $roleBArn)
    $results['Exact roleB principal used'] = (Write-Check "deployed + fixed trust = exactly $roleBArn (not :root, not :user/)" $exact)

    # Illustration: whom the broken policy WOULD trust (a user literally named roleB).
    $hypoUserPolicy = ('{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:AssumeRole","Resource":"' + $roleCArn + '"}]}') | ConvertFrom-Json
    $hypo = Test-AssumeRole -CallerArn $userRoleBArn -CallerPolicies @($hypoUserPolicy) -TargetRoleArn $roleCArn -TargetTrustPolicy $brokenTrust
    Write-Host ("  [info] broken trust would instead admit an IAM USER named roleB (if one existed): {0}" -f $(if ($hypo.Allowed) { 'ALLOWED' } else { 'DENIED' })) -ForegroundColor Yellow

    # ------------------------------------------------------------------
    Write-Step 'BUG 2 - s3:* on Resource "*" (over-permission)'
    $br = Get-Resources $brokenS3
    $results['Broken S3 Resource "*" detected'] = (Write-Check 'broken fixture: Action s3:* on Resource "*"' ((Join-Sorted $br) -eq '*' -and (Join-Sorted $brokenS3.Statement.Action) -eq 's3:*'))

    $overOk = $true
    foreach ($case in @(
            @('s3:ListBucket', $otherArn),
            @('s3:GetObject', "$otherArn/payroll.csv"),
            @('s3:DeleteBucket', $otherArn),
            @('s3:PutBucketPolicy', $otherArn),
            @('s3:ListAllMyBuckets', '*'))) {
        $d = Get-IdentityDecision -Policies @($brokenS3) -Action $case[0] -Resource $case[1]
        $overOk = (Write-Check "BROKEN allows $($case[0]) on $($case[1])" ($d -eq 'Allow') "=> $d (over-broad)") -and $overOk
    }
    $results['Broken policy permits unrelated S3 bucket'] = $overOk

    $tb = $true
    $to = $true
    $ub = $true
    $uo = $true
    foreach ($pair in @(@('fixed fixture', $fixedS3), @('deployed Terraform', $deployedS3))) {
        $name = $pair[0]
        $doc = $pair[1]
        $tb = (Write-Check "$name ListBucket target bucket ARN" ((Get-IdentityDecision -Policies @($doc) -Action 's3:ListBucket' -Resource $targetArn) -eq 'Allow') '=> ALLOW') -and $tb
        foreach ($a in @('s3:GetObject', 's3:PutObject', 's3:DeleteObject')) {
            $to = (Write-Check "$name $a target object" ((Get-IdentityDecision -Policies @($doc) -Action $a -Resource "$targetArn/poc/file.txt") -eq 'Allow') '=> ALLOW') -and $to
        }
        foreach ($a in @('s3:ListBucket', 's3:DeleteBucket', 's3:PutBucketPolicy')) {
            $ub = (Write-Check "$name $a unrelated bucket" ((Get-IdentityDecision -Policies @($doc) -Action $a -Resource $otherArn) -ne 'Allow') '=> DENY') -and $ub
        }
        $ub = (Write-Check "$name ListAllMyBuckets" ((Get-IdentityDecision -Policies @($doc) -Action 's3:ListAllMyBuckets' -Resource '*') -ne 'Allow') '=> DENY') -and $ub
        foreach ($a in @('s3:GetObject', 's3:PutObject')) {
            $uo = (Write-Check "$name $a unrelated object" ((Get-IdentityDecision -Policies @($doc) -Action $a -Resource "$otherArn/payroll.csv") -ne 'Allow') '=> DENY') -and $uo
        }
    }
    $results['Fixed target bucket permitted'] = $tb
    $results['Fixed target objects permitted'] = $to
    $results['Fixed unrelated bucket denied'] = $ub
    $results['Fixed unrelated objects denied'] = $uo

    # ------------------------------------------------------------------
    Write-Step 'Deployable Terraform contains neither broken pattern'
    $tfFiles = @(Get-ChildItem -Path $repoRoot -Recurse -File -Include '*.tf' | Where-Object { $_.FullName -notmatch '\\\.terraform\\' -and $_.FullName -notmatch '\\tests\\' })
    # Comment lines are excluded on purpose: role-c.tf documents the bug in a comment.
    # What matters is code - and the RENDERED policy, which is checked as well.
    $userHits = @($tfFiles | Select-String -Pattern ':user/roleB' -SimpleMatch | Where-Object { $_.Line -notmatch '^\s*(#|//)' })
    $renderedPrincipals = @(Get-Principals $deployedTrust)
    $noUser = ($userHits.Count -eq 0) -and (@($renderedPrincipals | Where-Object { $_ -match ':user/' }).Count -eq 0)
    $results['Deployable Terraform has no user/roleB'] = (Write-Check "no ':user/roleB' in $($tfFiles.Count) deployable .tf files or rendered roleC trust" $noUser)

    $roleCResources = @(Get-Resources $deployedS3)
    $noStar = (@($roleCResources | Where-Object { $_ -eq '*' -or $_ -eq 'arn:aws:s3:::*' }).Count -eq 0) -and ((Join-Sorted $roleCResources) -eq "$targetArn,$targetArn/*")
    $results['Deployable roleC S3 has no Resource "*"'] = (Write-Check 'rendered roleC policy = bucket ARN + bucket/* only' $noStar "($(Join-Sorted $roleCResources))")

    $refHits = @($tfFiles | Select-String -Pattern 'fixtures|broken-trust-policy|broken-s3-policy|task5' | Where-Object { $_.Line -notmatch '^\s*(#|//)' })
    $results['Broken fixtures are not referenced by Terraform'] = (Write-Check 'no deployable .tf references tests/fixtures/task5' ($refHits.Count -eq 0) "($($refHits.Count) hits)")

    $sameTrust = (Get-NormalizedPolicy $fixedTrust) -eq (Get-NormalizedPolicy $deployedTrust)
    $sameS3 = (Get-NormalizedPolicy $fixedS3) -eq (Get-NormalizedPolicy $deployedS3)
    $drift = (Write-Check 'fixed-trust-policy.json == rendered roleC trust' $sameTrust)
    $drift = (Write-Check 'fixed-s3-policy.json == rendered roleC policy' $sameS3) -and $drift
    $results['Fixed fixtures match deployable Terraform'] = $drift
}
catch {
    Write-Host "  ERROR: $_" -ForegroundColor Red
}
finally {
    $cleanupOk = Remove-TempWorkspace -Path $tempRoot
}

# ----------------------------------------------------------------------
Write-Host ''
Write-Host '==================== TASK 5 LOCAL POC SUMMARY ====================' -ForegroundColor Cyan
$expectedChecks = 15
$allPassed = ($results.Count -eq $expectedChecks)
if (-not $cleanupOk) {
    $allPassed = $false
    Write-Host ('{0,-56} {1}' -f 'TEMP workspace cleanup', 'FAIL') -ForegroundColor Red
}
foreach ($name in $results.Keys) {
    $passed = [bool]$results[$name]
    if (-not $passed) { $allPassed = $false }
    $label = 'FAIL'
    $color = 'Red'
    if ($passed) {
        $label = 'PASS'
        $color = 'Green'
    }
    Write-Host ('{0,-56} {1}' -f $name, $label) -ForegroundColor $color
}
Write-Host ''
if ($allPassed) {
    Write-Host "POC-5 (LOCAL): PASS  ($($results.Count)/$expectedChecks checks; no AWS resources were created)" -ForegroundColor Green
}
else {
    Write-Host "POC-5 (LOCAL): FAIL  ($($results.Count)/$expectedChecks checks ran)" -ForegroundColor Red
}
Write-Host 'IAM evaluator: POC MODEL ONLY' -ForegroundColor Yellow
Write-Host ''
Write-Host 'REAL AWS POC' -ForegroundColor Yellow
foreach ($line in @('Broken trust before-test', 'Fixed roleB -> roleC AssumeRole', 'Broken broad-S3 before-test', 'Fixed target-bucket access', 'Fixed other-bucket denial')) {
    Write-Host ('{0,-56} {1}' -f $line, 'PENDING') -ForegroundColor Yellow
}

if ($allPassed) { exit 0 }
exit 1
