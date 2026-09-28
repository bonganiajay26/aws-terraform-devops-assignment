<#
.SYNOPSIS
    Task 2 LOCAL POC - remote state + DynamoDB locking design, checked without an AWS account.
.DESCRIPTION
    1. Baseline         : scripts/validate-local.ps1 (repo-wide fmt/init/validate/hygiene)
    2. Bootstrap        : terraform fmt -check / init -backend=false / validate
    3. Bootstrap plan   : offline plan of bootstrap/ (TEMP copy, mock credentials,
                          zero AWS calls); asserts S3 security settings, versioning
                          and the DynamoDB LockID table; KMS toggle
    4. Negative inputs  : invalid bucket name / KMS ARN / retention rejected
    5. Guards           : prevent_destroy on the bucket and the lock table
    6. Backend config   : account-a and account-b - S3 backend, DynamoDB table,
                          different keys, values consistent with bootstrap,
                          real backend.hcl git-ignored
    7. No silent local  : real s3 backend + no credentials => init FAILS and no
                          local terraform.tfstate is created
    8. Local lock demo  : Terraform refuses a competing LOCAL-state writer.
                          This does NOT prove DynamoDB locking.

    REAL AWS POC (PENDING, tests/task2-test.md): S3 remote state actually created,
    DynamoDB state locking actually exercised, two concurrent Terraform operations
    tested against AWS.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\task2-local-poc.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$results = [ordered]@{}
Import-Module (Join-Path $PSScriptRoot 'OfflineWorkspace.psm1') -Force

$expectedBucket = 'aws-terraform-devops-assignment-tfstate-000000000000'
$expectedTable = 'aws-terraform-devops-assignment-tf-locks'
$expectedRegion = 'us-east-1'

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

function Get-After {
    # Planned "after" values of one resource address from plan JSON.
    param($Plan, [string]$Address)
    $rc = $Plan.resource_changes | Where-Object { $_.address -eq $Address }
    if (-not $rc) { return $null }
    return $rc.change.after
}

function Get-HclValue {
    # Reads `name = "value"` / `name = value` from a simple HCL file.
    param([string]$Path, [string]$Name)
    $line = Get-Content $Path | Where-Object { $_ -match "^\s*$Name\s*=" } | Select-Object -First 1
    if (-not $line) { return $null }
    return (($line -split '=', 2)[1].Trim() -replace '^"|"$', '')
}

$tempRoot = Join-Path $env:TEMP ("task2-poc-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

# Environment variables isolated for the "no credentials" test (restored in finally).
$awsVars = @('AWS_PROFILE', 'AWS_DEFAULT_PROFILE', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN',
    'AWS_CONFIG_FILE', 'AWS_SHARED_CREDENTIALS_FILE', 'AWS_EC2_METADATA_DISABLED')
$savedEnv = @{}
foreach ($v in $awsVars) { $savedEnv[$v] = [Environment]::GetEnvironmentVariable($v, 'Process') }

$plannedBucket = $null
$plannedTable = $null

try {
    # ------------------------------------------------------------------
    Write-Step '1. Baseline: validate-local.ps1 (repo-wide)'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'validate-local.ps1') -PocLabel 'BASELINE' *>&1 |
        Select-String -Pattern '^(Repository structure|Required files|terraform (fmt|init|validate)|Secret/state check|Git repository)\s|BASELINE|missing' |
        ForEach-Object { Write-Host "  $_" }
    $results['Baseline: repo fmt/init/validate/hygiene'] = ($LASTEXITCODE -eq 0)

    # ------------------------------------------------------------------
    Write-Step '2. Bootstrap: fmt / init / validate'
    $r = Invoke-Terraform @('-chdir=bootstrap', 'fmt', '-check', '-diff')
    $results['Bootstrap terraform fmt'] = (Write-Check 'terraform fmt -check (bootstrap)' ($r.Exit -eq 0))
    $r = Invoke-Terraform @('-chdir=bootstrap', 'init', '-backend=false', '-input=false', '-no-color')
    $results['Bootstrap terraform init'] = (Write-Check 'terraform init -backend=false (bootstrap)' ($r.Exit -eq 0))
    $r = Invoke-Terraform @('-chdir=bootstrap', 'validate', '-no-color')
    $results['Bootstrap terraform validate'] = (Write-Check 'terraform validate (bootstrap)' ($r.Exit -eq 0 -and $r.Text -match 'Success'))

    # ------------------------------------------------------------------
    Write-Step '3. Offline plan of bootstrap/ (TEMP copy, mock credentials, no AWS calls)'
    $ws = New-OfflineWorkspace -RepoRoot $repoRoot -Stack 'bootstrap' -Destination (Join-Path $tempRoot 'offline')
    $pluginDir = Get-RepoPluginDir -RepoRoot $repoRoot -Stack 'bootstrap'
    $r = Invoke-Terraform @("-chdir=$ws", 'init', '-backend=false', '-input=false', '-no-color', "-plugin-dir=$pluginDir")
    $planFile = Join-Path $tempRoot 'bootstrap.tfplan'
    if ($r.Exit -eq 0) {
        $r = Invoke-Terraform @("-chdir=$ws", 'plan', '-refresh=false', '-input=false', '-no-color', '-var-file=terraform.tfvars.example', "-out=$planFile")
        $r.Text -split "`n" | Where-Object { $_ -match 'will be created|^Plan:|Error' } | ForEach-Object { Write-Host "  $($_.Trim())" }
    }
    $securityOk = $false
    $versioningOk = $false
    $tableOk = $false
    if ($r.Exit -eq 0) {
        $plan = (& terraform "-chdir=$ws" show -json $planFile | Out-String | ConvertFrom-Json)

        $bucket = Get-After $plan 'aws_s3_bucket.state'
        $ver = Get-After $plan 'aws_s3_bucket_versioning.state'
        $sse = Get-After $plan 'aws_s3_bucket_server_side_encryption_configuration.state'
        $pab = Get-After $plan 'aws_s3_bucket_public_access_block.state'
        $own = Get-After $plan 'aws_s3_bucket_ownership_controls.state'
        $lc = Get-After $plan 'aws_s3_bucket_lifecycle_configuration.state'
        $pol = $plan.resource_changes | Where-Object { $_.address -eq 'aws_s3_bucket_policy.state' }
        $plannedBucket = $bucket.bucket

        Write-Host '  -- S3 security configuration'
        $securityOk = $true
        $securityOk = (Write-Check 'bucket name' ($bucket.bucket -eq $expectedBucket) "($($bucket.bucket))") -and $securityOk
        $securityOk = (Write-Check 'force_destroy = false' ($bucket.force_destroy -eq $false)) -and $securityOk
        $algo = $sse.rule[0].apply_server_side_encryption_by_default[0].sse_algorithm
        $securityOk = (Write-Check 'server-side encryption' ($algo -eq 'AES256') "($algo)") -and $securityOk
        $pabAll = ($pab.block_public_acls -and $pab.block_public_policy -and $pab.ignore_public_acls -and $pab.restrict_public_buckets)
        $securityOk = (Write-Check 'public access block: all 4 settings true' ([bool]$pabAll)) -and $securityOk
        $securityOk = (Write-Check 'ACLs disabled (BucketOwnerEnforced)' ($own.rule[0].object_ownership -eq 'BucketOwnerEnforced')) -and $securityOk
        $securityOk = (Write-Check 'TLS-only bucket policy planned' ($null -ne $pol)) -and $securityOk

        $kmsPlan = Join-Path $tempRoot 'bootstrap-kms.tfplan'
        $kmsArn = 'arn:aws:kms:us-east-1:000000000000:key/00000000-0000-0000-0000-000000000000'
        $rk = Invoke-Terraform @("-chdir=$ws", 'plan', '-refresh=false', '-input=false', '-no-color', '-var-file=terraform.tfvars.example', "-var=kms_key_arn=$kmsArn", "-out=$kmsPlan")
        $kmsOk = $false
        if ($rk.Exit -eq 0) {
            $pk = (& terraform "-chdir=$ws" show -json $kmsPlan | Out-String | ConvertFrom-Json)
            $rule = (Get-After $pk 'aws_s3_bucket_server_side_encryption_configuration.state').rule[0]
            $def = $rule.apply_server_side_encryption_by_default[0]
            $kmsOk = ($def.sse_algorithm -eq 'aws:kms' -and $def.kms_master_key_id -eq $kmsArn -and $rule.bucket_key_enabled -eq $true)
        }
        $securityOk = (Write-Check 'kms_key_arn option => aws:kms with bucket key' $kmsOk) -and $securityOk

        Write-Host '  -- S3 versioning'
        $versioningOk = $true
        $versioningOk = (Write-Check 'versioning Enabled' ($ver.versioning_configuration[0].status -eq 'Enabled')) -and $versioningOk
        $days = $lc.rule[0].noncurrent_version_expiration[0].noncurrent_days
        $keep = $lc.rule[0].noncurrent_version_expiration[0].newer_noncurrent_versions
        $versioningOk = (Write-Check 'old versions retained, then expired' ($lc.rule[0].status -eq 'Enabled' -and [int]$days -eq 90 -and [int]$keep -eq 10) "(noncurrent_days=$days, newest $keep kept)") -and $versioningOk

        Write-Host '  -- DynamoDB LockID configuration'
        $tbl = Get-After $plan 'aws_dynamodb_table.locks'
        $plannedTable = $tbl.name
        $tableOk = $true
        $tableOk = (Write-Check 'lock table name' ($tbl.name -eq $expectedTable) "($($tbl.name))") -and $tableOk
        $attr = $tbl.attribute | Select-Object -First 1
        $tableOk = (Write-Check 'hash key LockID (type S)' ($tbl.hash_key -eq 'LockID' -and $attr.name -eq 'LockID' -and $attr.type -eq 'S')) -and $tableOk
        $tableOk = (Write-Check 'PAY_PER_REQUEST billing' ($tbl.billing_mode -eq 'PAY_PER_REQUEST')) -and $tableOk
        $tableOk = (Write-Check 'deletion protection' ($tbl.deletion_protection_enabled -eq $true)) -and $tableOk
        $tableOk = (Write-Check 'point-in-time recovery' ($tbl.point_in_time_recovery[0].enabled -eq $true)) -and $tableOk
        $tableOk = (Write-Check 'server-side encryption' ($tbl.server_side_encryption[0].enabled -eq $true)) -and $tableOk
    }
    else {
        Write-Host $r.Text -ForegroundColor Red
    }
    $results['S3 security configuration'] = $securityOk
    $results['S3 versioning'] = $versioningOk
    $results['DynamoDB LockID configuration'] = $tableOk

    # ------------------------------------------------------------------
    Write-Step '4. Negative inputs (must be rejected)'
    $negOk = $true
    $negCases = [ordered]@{
        '-var=state_bucket_name=Invalid_Bucket_Name' = 'state_bucket_name must be a valid S3 bucket name'
        '-var=kms_key_arn=not-an-arn'                = 'kms_key_arn must be a KMS key ARN'
        '-var=noncurrent_version_retention_days=0'   = 'noncurrent_version_retention_days must be at least 1'
    }
    foreach ($arg in $negCases.Keys) {
        $r = Invoke-Terraform @("-chdir=$ws", 'plan', '-refresh=false', '-input=false', '-no-color', '-var-file=terraform.tfvars.example', $arg)
        $ok = ($r.Exit -ne 0) -and (($r.Text -replace '\s+', ' ') -like "*$($negCases[$arg])*")
        $negOk = (Write-Check $arg $ok) -and $negOk
    }
    $results['Invalid bootstrap inputs rejected'] = $negOk

    # ------------------------------------------------------------------
    Write-Step '5. prevent_destroy on state infrastructure'
    $mainTf = Get-Content -Raw (Join-Path $repoRoot 'bootstrap\main.tf')
    $guardOk = $true
    foreach ($res in @('resource "aws_s3_bucket" "state"', 'resource "aws_dynamodb_table" "locks"')) {
        $start = $mainTf.IndexOf($res)
        $ok = $false
        if ($start -ge 0) {
            $next = $mainTf.IndexOf('resource "', $start + 1)
            if ($next -lt 0) { $next = $mainTf.Length }
            $ok = ($mainTf.Substring($start, $next - $start) -match 'prevent_destroy\s*=\s*true')
        }
        $guardOk = (Write-Check "$res has prevent_destroy = true" $ok) -and $guardOk
    }
    $results['State infrastructure prevent_destroy'] = $guardOk

    # ------------------------------------------------------------------
    Write-Step '6. Backend configuration (S3 + DynamoDB, separate keys)'
    $keys = @{}
    foreach ($stack in @('account-a', 'account-b')) {
        Write-Host "  -- $stack"
        $stackOk = $true
        $beTf = Join-Path $repoRoot "$stack\backend.tf"
        $beContent = Get-Content -Raw $beTf
        $key = Get-HclValue $beTf 'key'
        $keys[$stack] = $key
        $stackOk = (Write-Check 'backend "s3"' ($beContent -match 'backend\s+"s3"')) -and $stackOk
        $stackOk = (Write-Check "state key = $stack/terraform.tfstate" ($key -eq "$stack/terraform.tfstate") "($key)") -and $stackOk
        $stackOk = (Write-Check 'encrypt = true' ($beContent -match 'encrypt\s*=\s*true')) -and $stackOk
        $stackOk = (Write-Check 'bucket not hard-coded (partial config)' ($beContent -notmatch '(?m)^\s*bucket\s*=')) -and $stackOk

        $example = Join-Path $repoRoot "$stack\backend.hcl.example"
        $exBucket = Get-HclValue $example 'bucket'
        $exTable = Get-HclValue $example 'dynamodb_table'
        $exRegion = Get-HclValue $example 'region'
        $exProfile = Get-HclValue $example 'profile'
        $stackOk = (Write-Check 'DynamoDB lock table configured = bootstrap table' ($null -ne $exTable -and $exTable -eq $plannedTable) "($exTable)") -and $stackOk
        $stackOk = (Write-Check 'bucket = bootstrap bucket, region matches' ($exBucket -eq $plannedBucket -and $exRegion -eq $expectedRegion)) -and $stackOk
        $stackOk = (Write-Check 'backend authenticates to state account (profile account-a)' ($exProfile -eq 'account-a')) -and $stackOk
        & git -C $repoRoot check-ignore -q "$stack/backend.hcl"
        $stackOk = (Write-Check "$stack/backend.hcl is git-ignored" ($LASTEXITCODE -eq 0)) -and $stackOk

        $label = 'Account A backend configuration'
        if ($stack -eq 'account-b') { $label = 'Account B backend configuration' }
        $results[$label] = $stackOk
    }
    $sep = (Write-Check 'account-a and account-b keys differ (separate state, separate lock item)' ($keys['account-a'] -ne $keys['account-b']))
    $results['Account A backend configuration'] = $results['Account A backend configuration'] -and $sep
    $results['Account B backend configuration'] = $results['Account B backend configuration'] -and $sep

    # ------------------------------------------------------------------
    Write-Step '7. Real s3 backend without credentials must FAIL (no silent local state)'
    $wsBackend = New-OfflineWorkspace -RepoRoot $repoRoot -Stack 'account-a' -Destination (Join-Path $tempRoot 'backend') -KeepBackend
    $emptyCfg = Join-Path $tempRoot 'no-such-aws-config'
    foreach ($v in $awsVars) { [Environment]::SetEnvironmentVariable($v, $null, 'Process') }
    $env:AWS_CONFIG_FILE = $emptyCfg
    $env:AWS_SHARED_CREDENTIALS_FILE = $emptyCfg
    $env:AWS_EC2_METADATA_DISABLED = 'true'
    $pluginDirA = Get-RepoPluginDir -RepoRoot $repoRoot -Stack 'account-a'
    $r = Invoke-Terraform @("-chdir=$wsBackend", 'init', '-input=false', '-no-color', '-backend-config=backend.hcl.example', "-plugin-dir=$pluginDirA")
    foreach ($v in $awsVars) { [Environment]::SetEnvironmentVariable($v, $savedEnv[$v], 'Process') }
    $r.Text -split "`n" | Where-Object { $_ -match '^\s*Error: ' } | Select-Object -First 2 | ForEach-Object { Write-Host "      $($_.Trim())" -ForegroundColor DarkGray }
    $silentOk = (Write-Check 'terraform init with s3 backend fails without credentials' ($r.Exit -ne 0))
    $silentOk = (Write-Check 'no local terraform.tfstate created' (-not (Test-Path (Join-Path $wsBackend 'terraform.tfstate')))) -and $silentOk
    $results['No silent fallback to local state'] = $silentOk

    # ------------------------------------------------------------------
    Write-Step '8. Local demo: competing LOCAL-state writer (not DynamoDB)'
    $demo = Join-Path $tempRoot 'lock-demo'
    Copy-Item -Recurse (Join-Path $repoRoot 'tests\task2-lock-demo') $demo
    $lockOk = $true
    $r = Invoke-Terraform @("-chdir=$demo", 'init', '-input=false', '-no-color')
    $lockOk = (Write-Check 'init' ($r.Exit -eq 0)) -and $lockOk

    $log1 = Join-Path $tempRoot 'p1.out'
    $err1 = Join-Path $tempRoot 'p1.err'
    $tfExe = (Get-Command terraform).Source
    $p1 = Start-Process -FilePath $tfExe -ArgumentList @("-chdir=$demo", 'apply', '-auto-approve', '-input=false', '-no-color') -NoNewWindow -PassThru -RedirectStandardOutput $log1 -RedirectStandardError $err1
    $null = $p1.Handle
    $lockInfo = Join-Path $demo '.terraform.tfstate.lock.info'
    $waited = 0
    while (-not (Test-Path $lockInfo) -and $waited -lt 60) {
        Start-Sleep -Milliseconds 500
        $waited++
    }
    $lockOk = (Write-Check 'process 1 (apply) holds the local state lock' (Test-Path $lockInfo)) -and $lockOk

    $r = Invoke-Terraform @("-chdir=$demo", 'plan', '-input=false', '-no-color', '-lock-timeout=0s')
    $p2Blocked = ($r.Exit -ne 0 -and $r.Text -match 'Error acquiring the state lock')
    $lockOk = (Write-Check 'process 2 refused: "Error acquiring the state lock"' $p2Blocked) -and $lockOk
    $r.Text -split "`n" | Where-Object { $_ -match '^\s*(Error: Error acquiring|read terraform.tfstate|process has locked)' } | ForEach-Object { Write-Host "      $($_.Trim())" -ForegroundColor DarkGray }

    $p1.WaitForExit()
    $lockOk = (Write-Check 'process 1 completed and released the lock' ($p1.ExitCode -eq 0 -and -not (Test-Path $lockInfo))) -and $lockOk
    $r = Invoke-Terraform @("-chdir=$demo", 'plan', '-input=false', '-no-color', '-lock-timeout=0s')
    $lockOk = (Write-Check 'after release, a new operation acquires the lock' ($r.Exit -eq 0)) -and $lockOk
    Write-Host '  [info] Windows local backend fails fast; -lock-timeout waiting is part of the REAL AWS POC.' -ForegroundColor Yellow
    $results['Local competing writer rejected'] = $lockOk
}
finally {
    foreach ($v in $awsVars) { [Environment]::SetEnvironmentVariable($v, $savedEnv[$v], 'Process') }
    Remove-TempWorkspace -Path $tempRoot
}

# ----------------------------------------------------------------------
Write-Host ''
Write-Host '==================== TASK 2 LOCAL POC SUMMARY ====================' -ForegroundColor Cyan
$allPassed = $true
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
    Write-Host 'POC-2 (LOCAL): PASS  (no AWS resources were created)' -ForegroundColor Green
}
else {
    Write-Host 'POC-2 (LOCAL): FAIL' -ForegroundColor Red
}
Write-Host ''
Write-Host 'REAL AWS POC' -ForegroundColor Yellow
Write-Host ('{0,-56} {1}' -f 'S3 remote state actually created.', 'PENDING') -ForegroundColor Yellow
Write-Host ('{0,-56} {1}' -f 'DynamoDB state locking actually exercised.', 'PENDING') -ForegroundColor Yellow
Write-Host ('{0,-56} {1}' -f 'Two concurrent Terraform operations tested against AWS.', 'PENDING') -ForegroundColor Yellow

if ($allPassed) { exit 0 }
exit 1
