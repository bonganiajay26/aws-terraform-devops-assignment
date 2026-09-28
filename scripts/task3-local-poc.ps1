<#
.SYNOPSIS
    Task 3 LOCAL POC - multi-account IAM, checked without AWS accounts.
.DESCRIPTION
    1. Baseline          : scripts/validate-local.ps1
    2. Offline plans     : account-a and account-b (TEMP copies, mock credentials,
                           zero AWS calls); the rendered policy JSON is extracted
    3. Users and groups  : group1 = engine+ci (never a login profile), group2 = two
                           console+CLI users; default plan creates NO login profile
                           (no password in state); with console_pgp_key, profiles
                           for group2 only, PGP-encrypted, reset required;
                           no aws_iam_access_key anywhere, no secret outputs
    4. roleA structure   : Allow NotAction iam:* + explicit Deny iam:*;
                           no AdministratorAccess/PowerUserAccess attached
    5. roleB structure   : exactly one permission: sts:AssumeRole on exact roleC ARN;
                           no managed policies attached
    6. roleC structure   : trusts EXACTLY arn:aws:iam::<A>:role/roleB (no :root,
                           no :user/, no *); s3:* on bucket ARN + bucket/* ARN only
    7. Cross-stack       : ARNs used by account-a and account-b agree
    8. Access matrix     : assignment tests A-E (and extras) evaluated with the
                           simplified IAM model (IamPolicyModel.psm1) against the
                           Terraform-rendered policies, incl. a counterfactual
                           showing why trusting Account A root is broader
    9. Negative inputs   : invalid console users / account ID rejected

    REAL AWS POC (PENDING, tests/task3-test.md): actual roleB -> AssumeRole ->
    roleC -> S3 calls between two real accounts.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\task3-local-poc.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$results = [ordered]@{}
Import-Module (Join-Path $PSScriptRoot 'OfflineWorkspace.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'IamPolicyModel.psm1') -Force

$accountA = '000000000000'
$accountB = '111111111111'
$roleAArn = "arn:aws:iam::${accountA}:role/roleA"
$roleBArn = "arn:aws:iam::${accountA}:role/roleB"
$roleCArn = "arn:aws:iam::${accountB}:role/roleC"
$targetBucket = 'aws-terraform-devops-assignment-crossacct-111111111111'
$controlBucket = 'aws-terraform-devops-assignment-control-111111111111'
$targetArn = "arn:aws:s3:::$targetBucket"
$controlArn = "arn:aws:s3:::$controlBucket"

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

function Get-Plan {
    param([string]$Stack, [string]$TempRoot, [string[]]$ExtraArgs = @())
    $ws = New-OfflineWorkspace -RepoRoot $repoRoot -Stack $Stack -Destination (Join-Path $TempRoot $Stack)
    $pluginDir = Get-RepoPluginDir -RepoRoot $repoRoot -Stack $Stack
    $r = Invoke-Terraform @("-chdir=$ws", 'init', '-backend=false', '-input=false', '-no-color', "-plugin-dir=$pluginDir")
    if ($r.Exit -ne 0) { return @{ Ok = $false; Text = $r.Text; Workspace = $ws } }
    $planFile = Join-Path $TempRoot "$Stack.tfplan"
    $r = Invoke-Terraform (@("-chdir=$ws", 'plan', '-refresh=false', '-input=false', '-no-color', "-out=$planFile") + $ExtraArgs)
    if ($r.Exit -ne 0) { return @{ Ok = $false; Text = $r.Text; Workspace = $ws } }
    $json = (& terraform "-chdir=$ws" show -json $planFile | Out-String | ConvertFrom-Json)
    return @{ Ok = $true; Plan = $json; Workspace = $ws; Text = $r.Text }
}

function Get-After {
    param($Plan, [string]$Address)
    $rc = $Plan.resource_changes | Where-Object { $_.address -eq $Address }
    if (-not $rc) { return $null }
    return $rc.change.after
}

function Get-Doc {
    # Parses a policy JSON string attribute from plan "after" values.
    param($After, [string]$Attribute)
    if ($null -eq $After) { return $null }
    $raw = $After.$Attribute
    if ([string]::IsNullOrEmpty($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function As-List {
    # The leading comma stops PowerShell from unrolling a 1-element array,
    # so .Count is always reliable for the caller.
    param($Value)
    if ($null -eq $Value) { return , @() }
    return , @($Value)
}

$tempRoot = Join-Path $env:TEMP ("task3-poc-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
    $pa = Get-Plan -Stack 'account-a' -TempRoot $tempRoot -ExtraArgs @('-var-file=terraform.tfvars.example')
    $pb = Get-Plan -Stack 'account-b' -TempRoot $tempRoot
    foreach ($p in @(@('account-a', $pa), @('account-b', $pb))) {
        $summary = ($p[1].Text -split "`n" | Where-Object { $_ -match '^Plan:' }) -join ''
        if (-not $p[1].Ok) { Write-Host $p[1].Text -ForegroundColor Red }
        [void](Write-Check "$($p[0]) offline plan" $p[1].Ok $summary.Trim())
    }
    if (-not ($pa.Ok -and $pb.Ok)) {
        $results['Account A IAM structure'] = $false
        $results['Account B IAM structure'] = $false
        throw 'Offline plan failed - cannot continue.'
    }
    $planA = $pa.Plan
    $planB = $pb.Plan
    $allChanges = @($planA.resource_changes) + @($planB.resource_changes)

    $typesA = @($planA.resource_changes | ForEach-Object { $_.address })
    $typesB = @($planB.resource_changes | ForEach-Object { $_.address })
    $needA = @('aws_iam_group.group1', 'aws_iam_group.group2', 'aws_iam_group_membership.group1', 'aws_iam_group_membership.group2',
        'aws_iam_group_policy.group2', 'aws_iam_user_policy.engine', 'aws_iam_role.role_a', 'aws_iam_policy.role_a_admin_except_iam',
        'aws_iam_role_policy_attachment.role_a_admin_except_iam', 'aws_iam_role.role_b', 'aws_iam_role_policy.role_b')
    $needB = @('aws_iam_role.role_c', 'aws_iam_role_policy.role_c', 'aws_s3_bucket.target', 'aws_s3_bucket_public_access_block.target', 'aws_s3_bucket_policy.target')
    $missA = @($needA | Where-Object { $typesA -notcontains $_ })
    $missB = @($needB | Where-Object { $typesB -notcontains $_ })
    $results['Account A IAM structure'] = (Write-Check 'Account A: groups, users, memberships, roleA, roleB, policies planned' ($missA.Count -eq 0) "(missing: $($missA -join ', '))")
    $results['Account B IAM structure'] = (Write-Check 'Account B: roleC, roleC policy, target bucket planned' ($missB.Count -eq 0) "(missing: $($missB -join ', '))")

    # Rendered policy documents (the objects under test).
    $docGroup2 = Get-Doc (Get-After $planA 'aws_iam_group_policy.group2') 'policy'
    $docEngine = Get-Doc (Get-After $planA 'aws_iam_user_policy.engine') 'policy'
    $docRoleATrust = Get-Doc (Get-After $planA 'aws_iam_role.role_a') 'assume_role_policy'
    $docRoleA = Get-Doc (Get-After $planA 'aws_iam_policy.role_a_admin_except_iam') 'policy'
    $docRoleBTrust = Get-Doc (Get-After $planA 'aws_iam_role.role_b') 'assume_role_policy'
    $docRoleB = Get-Doc (Get-After $planA 'aws_iam_role_policy.role_b') 'policy'
    $docRoleCTrust = Get-Doc (Get-After $planB 'aws_iam_role.role_c') 'assume_role_policy'
    $docRoleC = Get-Doc (Get-After $planB 'aws_iam_role_policy.role_c') 'policy'

    # ------------------------------------------------------------------
    Write-Step '3. Users and groups (Account A) - authorization configured, credentials NOT provisioned'
    $users = @($planA.resource_changes | Where-Object { $_.type -eq 'aws_iam_user' } | ForEach-Object { $_.change.after.name } | Sort-Object)
    $g1 = @((Get-After $planA 'aws_iam_group_membership.group1').users | Sort-Object)
    $g2 = @((Get-After $planA 'aws_iam_group_membership.group2').users | Sort-Object)
    [void](Write-Check 'four IAM users' (($users -join ',') -eq 'ci,developer1,developer2,engine') "($($users -join ', '))")
    $results['group1 contains engine + ci'] = (Write-Check 'group1 = engine, ci' (($g1 -join ',') -eq 'ci,engine') "($($g1 -join ', '))")
    $results['group2 contains developer1 + developer2'] = (Write-Check 'group2 = developer1, developer2' (($g2 -join ',') -eq 'developer1,developer2') "($($g2 -join ', '))")

    # Default (no PGP key): no login profile at all => no generated password in state.
    $defaultProfiles = @($planA.resource_changes | Where-Object { $_.type -eq 'aws_iam_user_login_profile' })
    $defaultUsers = @($defaultProfiles | ForEach-Object { $_.change.after.user })

    # PGP mode - LOCAL STRUCTURAL VALIDATION ONLY. The placeholder
    # "keybase:placeholder-user" only proves the Terraform configuration path; it
    # is NOT a usable key and would fail to encrypt on a real apply.
    $pgpPlan = Join-Path $tempRoot 'account-a-pgp.tfplan'
    $rp = Invoke-Terraform @("-chdir=$($pa.Workspace)", 'plan', '-refresh=false', '-input=false', '-no-color', '-var-file=terraform.tfvars.example', '-var=console_pgp_key=keybase:placeholder-user', "-out=$pgpPlan")
    $profiles = @()
    $pgpOutputs = @()
    if ($rp.Exit -eq 0) {
        $pgpJson = (& terraform "-chdir=$($pa.Workspace)" show -json $pgpPlan | Out-String | ConvertFrom-Json)
        $profiles = @($pgpJson.resource_changes | Where-Object { $_.type -eq 'aws_iam_user_login_profile' })
        $pgpOutputs = @($pgpJson.output_changes.PSObject.Properties.Name)
    }
    $profileUsers = @($profiles | ForEach-Object { $_.change.after.user } | Sort-Object)

    $g1NoProfile = -not (($defaultUsers + $profileUsers) | Where-Object { $_ -eq 'engine' -or $_ -eq 'ci' })
    $results['group1 login profiles absent'] = (Write-Check 'engine / ci: no login profile in either mode' ([bool]$g1NoProfile))
    $keys = @($allChanges | Where-Object { $_.type -eq 'aws_iam_access_key' })
    $results['Terraform-managed access keys absent'] = (Write-Check 'no aws_iam_access_key resources (both accounts)' ($keys.Count -eq 0))
    $results['group2 default login profiles absent'] = (Write-Check 'default mode: NO login profiles => no password in state' ($defaultProfiles.Count -eq 0) "($($defaultProfiles.Count))")
    $pgpShape = (($profileUsers -join ',') -eq 'developer1,developer2') -and
                (@($profiles | Where-Object { $_.change.after.pgp_key -ne 'keybase:placeholder-user' }).Count -eq 0)
    $results['group2 PGP-mode profile configuration'] = (Write-Check 'PGP mode (structural): profiles for group2 only, pgp_key wired' $pgpShape "($($profileUsers -join ', '))")
    $resetAll = ($profiles.Count -gt 0) -and (@($profiles | Where-Object { $_.change.after.password_reset_required -ne $true }).Count -eq 0)
    $results['password_reset_required = true'] = (Write-Check 'password_reset_required = true on every profile' $resetAll)
    $outNames = @($planA.output_changes.PSObject.Properties.Name) + @($planB.output_changes.PSObject.Properties.Name) + $pgpOutputs
    $badOut = @($outNames | Where-Object { $_ -match 'secret|access_key' -or ($_ -match 'password' -and $_ -notmatch 'encrypted') })
    $results['plaintext password outputs absent'] = (Write-Check 'no secret / plaintext password outputs (both modes)' ($badOut.Count -eq 0) "($($outNames.Count) outputs checked)")
    $selfService = (($docGroup2.Statement | Where-Object { $_.Sid -eq 'ManageOwnPasswordAndAccessKeys' }).Resource -eq "arn:aws:iam::${accountA}:user/`${aws:username}")
    $results['group2 self-service scoped to own user'] = (Write-Check 'group2 self-service (password/keys/MFA) scoped to ${aws:username}' $selfService)
    Write-Host '  [info] PGP mode uses a placeholder key: local structural validation only, not proof that' -ForegroundColor Yellow
    Write-Host '         encryption works against real AWS (a real apply needs a valid public key).' -ForegroundColor Yellow
    Write-Host '  [info] Credential provisioning is intentionally excluded; permissions support the access model.' -ForegroundColor Yellow

    # ------------------------------------------------------------------
    Write-Step '4. roleA - admin except IAM'
    $ok = $true
    $allowSt = $docRoleA.Statement | Where-Object { $_.Effect -eq 'Allow' }
    $denySt = $docRoleA.Statement | Where-Object { $_.Effect -eq 'Deny' }
    $ok = (Write-Check 'Allow NotAction iam:* on *' ($null -ne $allowSt -and (As-List $allowSt.NotAction) -contains 'iam:*' -and $null -eq $allowSt.Action -and $allowSt.Resource -eq '*')) -and $ok
    $ok = (Write-Check 'explicit Deny iam:*' ($null -ne $denySt -and (As-List $denySt.Action) -contains 'iam:*')) -and $ok
    $attachments = @($allChanges | Where-Object { $_.type -match 'policy_attachment' } | ForEach-Object { $_.change.after.policy_arn } | Where-Object { $_ })
    $broad = @($attachments | Where-Object { $_ -match 'AdministratorAccess|PowerUserAccess|FullAccess' })
    $ok = (Write-Check 'no AdministratorAccess / PowerUserAccess / *FullAccess attached' ($broad.Count -eq 0)) -and $ok
    $trustA = @(@($docRoleATrust.Statement[0].Principal.AWS) | Sort-Object)
    $mfa = $docRoleATrust.Statement[0].Condition.Bool.'aws:MultiFactorAuthPresent'
    $ok = (Write-Check 'roleA trusted by developer1/developer2 only, MFA required' ((($trustA -join ',') -eq "arn:aws:iam::${accountA}:user/developer1,arn:aws:iam::${accountA}:user/developer2") -and $mfa -eq 'true')) -and $ok
    $results['roleA admin except IAM'] = $ok

    # ------------------------------------------------------------------
    Write-Step '5. roleB - ONLY sts:AssumeRole on roleC'
    $ok = $true
    $st = As-List $docRoleB.Statement
    $ok = (Write-Check 'exactly one statement' ($st.Count -eq 1)) -and $ok
    $ok = (Write-Check 'exactly one action: sts:AssumeRole' (((As-List $st[0].Action) -join ',') -eq 'sts:AssumeRole' -and $st[0].Effect -eq 'Allow')) -and $ok
    $ok = (Write-Check 'resource = exact roleC ARN' (((As-List $st[0].Resource) -join ',') -eq $roleCArn) "($($st[0].Resource))") -and $ok
    $roleBAttach = @($planA.resource_changes | Where-Object { $_.type -eq 'aws_iam_role_policy_attachment' -and $_.change.after.role -eq 'roleB' })
    $ok = (Write-Check 'no managed policies attached to roleB' ($roleBAttach.Count -eq 0)) -and $ok
    $roleBInline = @($planA.resource_changes | Where-Object { $_.type -eq 'aws_iam_role_policy' -and $_.address -like '*role_b*' })
    $ok = (Write-Check 'exactly one inline policy on roleB' ($roleBInline.Count -eq 1)) -and $ok
    $results['roleB only AssumeRole exact roleC'] = $ok

    # ------------------------------------------------------------------
    Write-Step '6. roleC - trust ONLY roleB, S3 ONLY target bucket'
    $tst = As-List $docRoleCTrust.Statement
    $principals = @()
    foreach ($s in $tst) { $principals += As-List $s.Principal.AWS }
    $exact = ($principals.Count -eq 1 -and $tst.Count -eq 1 -and $principals[0] -eq $roleBArn)
    $results['roleC trusts exact roleB'] = (Write-Check "exactly one trusted principal = $roleBArn" $exact)
    $noRoot = (@($principals | Where-Object { $_ -match ':root$' -or $_ -match '^\d{12}$' -or $_ -match '\*' }).Count -eq 0)
    $results['Account-A root trust absent'] = (Write-Check 'NOT account root (:root / account ID / *)' $noRoot)
    $noUser = (@($principals | Where-Object { $_ -match ':user/' }).Count -eq 0)
    $results['user/roleB trust absent'] = (Write-Check 'NOT a user ARN (:user/roleB)' $noUser)
    $cst = As-List $docRoleC.Statement
    $res = @($cst | ForEach-Object { $_.Resource } | ForEach-Object { $_ } | Sort-Object)
    $scope = (($res -join ',') -eq "$targetArn,$targetArn/*") -and (((As-List $cst[0].Action) -join ',') -eq 's3:*')
    $results['roleC S3 target-bucket scope'] = (Write-Check 's3:* on bucket ARN + bucket/* ARN exactly' $scope "($($res -join ', '))")
    $noStar = (@($res | Where-Object { $_ -eq '*' -or $_ -eq 'arn:aws:s3:::*' }).Count -eq 0)
    $results['Resource "*" absent from roleC S3 policy'] = (Write-Check 'no Resource "*" (or arn:aws:s3:::*)' $noStar)

    # ------------------------------------------------------------------
    Write-Step '7. Cross-stack ARN consistency'
    $ok = $true
    $roleBName = (Get-After $planA 'aws_iam_role.role_b').name
    $roleCName = (Get-After $planB 'aws_iam_role.role_c').name
    $ok = (Write-Check 'roleC trust principal == account-a roleB (name roleB)' ($principals[0] -eq "arn:aws:iam::${accountA}:role/$roleBName")) -and $ok
    $ok = (Write-Check 'roleB permission target == account-b roleC (name roleC)' ($st[0].Resource -eq "arn:aws:iam::${accountB}:role/$roleCName")) -and $ok
    $targetPlanned = (Get-After $planB 'aws_s3_bucket.target').bucket
    $ok = (Write-Check 'roleC bucket ARN == planned target bucket' ($targetArn -eq "arn:aws:s3:::$targetPlanned")) -and $ok
    $results['Cross-account ARNs consistent'] = $ok

    # ------------------------------------------------------------------
    Write-Step '8. Access matrix - simplified IAM model on Terraform-rendered policies (NOT AWS)'
    $mfaCtx = @{ ConditionKeys = @{ 'aws:MultiFactorAuthPresent' = 'true' } }
    $noMfaCtx = @{ ConditionKeys = @{ 'aws:MultiFactorAuthPresent' = 'false' } }
    $identities = @{
        engine     = @{ Arn = "arn:aws:iam::${accountA}:user/engine"; Policies = @($docEngine); Ctx = @{ Username = 'engine' } }
        ci         = @{ Arn = "arn:aws:iam::${accountA}:user/ci"; Policies = @(); Ctx = @{ Username = 'ci' } }
        developer1 = @{ Arn = "arn:aws:iam::${accountA}:user/developer1"; Policies = @($docGroup2); Ctx = @{ Username = 'developer1' } }
        roleA      = @{ Arn = $roleAArn; Policies = @($docRoleA); Ctx = @{} }
        roleB      = @{ Arn = $roleBArn; Policies = @($docRoleB); Ctx = @{} }
        roleC      = @{ Arn = $roleCArn; Policies = @($docRoleC); Ctx = @{} }
    }
    $matrixOk = $true

    function Test-Assume {
        param([string]$Id, [string]$Target, $Trust, [bool]$Expect, [string]$Label, [hashtable]$ExtraCtx = @{}, [switch]$Root)
        $callerArn = "arn:aws:iam::${accountA}:root"
        $pol = @()
        $ctx = @{}
        if (-not $Root) {
            $callerArn = $identities[$Id].Arn
            $pol = $identities[$Id].Policies
            $ctx = $identities[$Id].Ctx.Clone()
        }
        foreach ($k in $ExtraCtx.Keys) { $ctx[$k] = $ExtraCtx[$k] }
        $r = Test-AssumeRole -CallerArn $callerArn -CallerPolicies $pol -TargetRoleArn $Target -TargetTrustPolicy $Trust -Context $ctx -IsAccountRoot:$Root
        $verdict = 'DENIED'
        if ($r.Allowed) { $verdict = 'ALLOWED' }
        return (Write-Check $Label ($r.Allowed -eq $Expect) "=> $verdict (identity=$($r.Identity), trust=$($r.Trust))")
    }

    function Test-Action {
        param([string]$Id, [string]$Action, [string]$Resource, [bool]$Expect, [string]$Label)
        $d = Get-IdentityDecision -Policies $identities[$Id].Policies -Action $Action -Resource $Resource -Context $identities[$Id].Ctx
        return (Write-Check $Label (($d -eq 'Allow') -eq $Expect) "=> $d")
    }

    Write-Host '  -- TEST A: assume roleB'
    $matrixOk = (Test-Assume 'engine' $roleBArn $docRoleBTrust $true 'A  engine -> AssumeRole roleB') -and $matrixOk
    $matrixOk = (Test-Assume 'ci' $roleBArn $docRoleBTrust $false 'A- ci -> AssumeRole roleB') -and $matrixOk
    Write-Host '  -- TEST B: roleB -> roleC (cross-account)'
    $matrixOk = (Test-Assume 'roleB' $roleCArn $docRoleCTrust $true 'B  roleB -> AssumeRole roleC') -and $matrixOk
    Write-Host '  -- TEST C: roleC -> target bucket'
    $matrixOk = (Test-Action 'roleC' 's3:ListBucket' $targetArn $true 'C  roleC s3:ListBucket target (bucket ARN)') -and $matrixOk
    $matrixOk = (Test-Action 'roleC' 's3:GetObject' "$targetArn/poc/test.txt" $true 'C  roleC s3:GetObject target/* (object ARN)') -and $matrixOk
    $matrixOk = (Test-Action 'roleC' 's3:PutObject' "$targetArn/poc/test.txt" $true 'C  roleC s3:PutObject target/*') -and $matrixOk
    $matrixOk = (Test-Action 'roleC' 's3:DeleteObject' "$targetArn/poc/test.txt" $true 'C  roleC s3:DeleteObject target/*') -and $matrixOk
    Write-Host '  -- TEST D: roleC -> another bucket'
    $matrixOk = (Test-Action 'roleC' 's3:ListBucket' $controlArn $false 'D  roleC s3:ListBucket control bucket') -and $matrixOk
    $matrixOk = (Test-Action 'roleC' 's3:GetObject' "$controlArn/x" $false 'D  roleC s3:GetObject control bucket') -and $matrixOk
    $matrixOk = (Test-Action 'roleC' 's3:ListAllMyBuckets' '*' $false 'D  roleC s3:ListAllMyBuckets') -and $matrixOk
    Write-Host '  -- TEST E: unauthorized Account-A principals -> roleC'
    $matrixOk = (Test-Assume 'roleA' $roleCArn $docRoleCTrust $false 'E  roleA (admin, has sts:AssumeRole *) -> roleC') -and $matrixOk
    $matrixOk = (Test-Assume 'engine' $roleCArn $docRoleCTrust $false 'E  engine -> roleC directly (skipping roleB)') -and $matrixOk
    $matrixOk = (Test-Assume 'ci' $roleCArn $docRoleCTrust $false 'E  ci -> roleC') -and $matrixOk
    $matrixOk = (Test-Assume 'developer1' $roleCArn $docRoleCTrust $false 'E  developer1 -> roleC') -and $matrixOk
    $matrixOk = (Test-Assume '' $roleCArn $docRoleCTrust $false 'E  Account A root -> roleC' -Root) -and $matrixOk
    Write-Host '  -- roleB has nothing else'
    foreach ($a in @(@('ec2:DescribeInstances', '*'), @('s3:ListAllMyBuckets', '*'), @('s3:GetObject', "$targetArn/x"), @('iam:ListUsers', '*'), @('ecr:GetAuthorizationToken', '*'), @('ecs:ListClusters', '*'))) {
        $matrixOk = (Test-Action 'roleB' $a[0] $a[1] $false "   roleB $($a[0])") -and $matrixOk
    }
    $matrixOk = (Test-Assume 'roleB' "arn:aws:iam::${accountB}:role/SomeOtherRole" $docRoleCTrust $false '   roleB -> AssumeRole a different role in Account B') -and $matrixOk
    Write-Host '  -- roleA: everything except IAM'
    $matrixOk = (Test-Action 'roleA' 'ec2:RunInstances' '*' $true '   roleA ec2:RunInstances') -and $matrixOk
    $matrixOk = (Test-Action 'roleA' 's3:CreateBucket' 'arn:aws:s3:::any-bucket' $true '   roleA s3:CreateBucket') -and $matrixOk
    $matrixOk = (Test-Action 'roleA' 'dynamodb:CreateTable' '*' $true '   roleA dynamodb:CreateTable') -and $matrixOk
    $matrixOk = (Test-Action 'roleA' 'iam:CreateUser' '*' $false '   roleA iam:CreateUser') -and $matrixOk
    $matrixOk = (Test-Action 'roleA' 'iam:AttachRolePolicy' '*' $false '   roleA iam:AttachRolePolicy') -and $matrixOk
    $matrixOk = (Test-Action 'roleA' 'iam:PassRole' '*' $false '   roleA iam:PassRole') -and $matrixOk
    Write-Host '  -- group2 users need MFA for roleA'
    $matrixOk = (Test-Assume 'developer1' $roleAArn $docRoleATrust $true '   developer1 (MFA) -> roleA' -ExtraCtx $mfaCtx) -and $matrixOk
    $matrixOk = (Test-Assume 'developer1' $roleAArn $docRoleATrust $false '   developer1 (no MFA) -> roleA' -ExtraCtx $noMfaCtx) -and $matrixOk
    $results['Local IAM evaluator: tests A-E (model, not AWS)'] = $matrixOk

    Write-Host '  -- COUNTERFACTUAL: roleC trusting arn:aws:iam::000000000000:root (NOT deployed)'
    $rootTrust = ('{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:AssumeRole","Principal":{"AWS":"arn:aws:iam::' + $accountA + ':root"}}]}') | ConvertFrom-Json
    $cf = $true
    $cf = (Test-Assume 'roleB' $roleCArn $rootTrust $true '   root-trust: roleB -> roleC (still works)') -and $cf
    $cf = (Test-Assume 'roleA' $roleCArn $rootTrust $true '   root-trust: roleA -> roleC (NOW ALLOWED - broader!)') -and $cf
    $cf = (Test-Assume '' $roleCArn $rootTrust $true '   root-trust: Account A root -> roleC (NOW ALLOWED)' -Root) -and $cf
    $cf = (Test-Assume 'ci' $roleCArn $rootTrust $false '   root-trust: ci -> roleC (denied only by ci identity policy)') -and $cf
    $results['Local IAM evaluator: root trust broader (model)'] = $cf

    # ------------------------------------------------------------------
    Write-Step '9. Negative inputs (must be rejected)'
    $negOk = $true
    $negCases = [ordered]@{
        'invalid-console-user-is-engine.vars.hcl' = 'engine and ci are programmatic-only'
        'invalid-three-console-users.vars.hcl'    = 'console_user_names must contain exactly two distinct names'
        'invalid-account-b-id.vars.hcl'           = 'account_b_id must be exactly 12 digits'
    }
    foreach ($fixture in $negCases.Keys) {
        $fixturePath = Join-Path $repoRoot "tests\fixtures\task3\$fixture"
        $r = Invoke-Terraform @("-chdir=$($pa.Workspace)", 'plan', '-refresh=false', '-input=false', '-no-color', '-var-file=terraform.tfvars.example', "-var-file=$fixturePath")
        $ok = ($r.Exit -ne 0) -and (($r.Text -replace '\s+', ' ') -like "*$($negCases[$fixture])*")
        $negOk = (Write-Check $fixture $ok) -and $negOk
    }
    $results['Invalid IAM inputs rejected'] = $negOk
}
catch {
    Write-Host "  ERROR: $_" -ForegroundColor Red
}
finally {
    Remove-TempWorkspace -Path $tempRoot
}

# ----------------------------------------------------------------------
Write-Host ''
Write-Host '==================== TASK 3 LOCAL POC SUMMARY ====================' -ForegroundColor Cyan
$expectedChecks = 23
$allPassed = ($results.Count -eq $expectedChecks)
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
    Write-Host 'POC-3 (LOCAL): PASS  (no AWS resources were created)' -ForegroundColor Green
}
else {
    Write-Host "POC-3 (LOCAL): FAIL  ($($results.Count)/$expectedChecks checks ran)" -ForegroundColor Red
}
Write-Host ''
Write-Host 'REAL AWS POC' -ForegroundColor Yellow
Write-Host ('{0,-56} {1}' -f 'TEST A engine -> roleB', 'PENDING') -ForegroundColor Yellow
Write-Host ('{0,-56} {1}' -f 'TEST B roleB -> roleC', 'PENDING') -ForegroundColor Yellow
Write-Host ('{0,-56} {1}' -f 'TEST C roleC -> target bucket', 'PENDING') -ForegroundColor Yellow
Write-Host ('{0,-56} {1}' -f 'TEST D roleC -> other bucket denied', 'PENDING') -ForegroundColor Yellow
Write-Host ('{0,-56} {1}' -f 'TEST E unauthorized principal -> roleC denied', 'PENDING') -ForegroundColor Yellow
Write-Host ('{0,-56} {1}' -f 'Actual console/CLI authentication', 'PENDING') -ForegroundColor Yellow
Write-Host ('{0,-56} {1}' -f 'Real PGP-encrypted login profile (valid key)', 'PENDING') -ForegroundColor Yellow

if ($allPassed) { exit 0 }
exit 1
