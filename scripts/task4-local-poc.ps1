<#
.SYNOPSIS
    Task 4 LOCAL POC - ci least-privilege policy, checked without an AWS account.
.DESCRIPTION
    1. Baseline            : scripts/validate-local.ps1
    2. Offline plan        : account-a (TEMP copy, mock credentials, zero AWS calls)
    3. Policy structure    : customer-managed ci-least-privilege policy attached to the
                             ci USER only (not group1 / engine)
    4. Rendered JSON       : exact statements and ARNs; identical to policies/ci-policy.json
    5. Wildcard exceptions : Resource "*" ONLY for ecr:GetAuthorizationToken and
                             ecs:RegisterTaskDefinition, each alone in its statement;
                             no action wildcards, no NotAction/NotResource, no Deny tricks
    6. Broad policies      : no AdministratorAccess / PowerUserAccess / *FullAccess /
                             ECR PowerUser attachments anywhere in the plan
    7. Excluded actions    : explicit list of dangerous actions absent from the policy
    8. Access matrix A-Q   : simplified IAM model (IamPolicyModel.psm1, NOT AWS) on the
                             Terraform-rendered policy
    9. Negative inputs     : wildcard repository / service / role / bucket names rejected

    REAL AWS POC (PENDING, tests/task4-test.md): actual ECR push, task definition
    registration, service deployment, iam:PassRole, S3 read and negative calls.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\task4-local-poc.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$results = [ordered]@{}
Import-Module (Join-Path $PSScriptRoot 'OfflineWorkspace.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'IamPolicyModel.psm1') -Force

$acct = '000000000000'
$region = 'us-east-1'
$repoArn = "arn:aws:ecr:${region}:${acct}:repository/aws-terraform-devops-assignment-app"
$otherRepoArn = "arn:aws:ecr:${region}:${acct}:repository/some-other-repo"
$serviceArn = "arn:aws:ecs:${region}:${acct}:service/aws-terraform-devops-assignment-cluster/aws-terraform-devops-assignment-service"
$otherServiceArn = "arn:aws:ecs:${region}:${acct}:service/aws-terraform-devops-assignment-cluster/payments-service"
$otherClusterServiceArn = "arn:aws:ecs:${region}:${acct}:service/prod-cluster/aws-terraform-devops-assignment-service"
$execRoleArn = "arn:aws:iam::${acct}:role/aws-terraform-devops-assignment-ecs-execution"
$taskRoleArn = "arn:aws:iam::${acct}:role/aws-terraform-devops-assignment-ecs-task"
$bucketArn = "arn:aws:s3:::aws-terraform-devops-assignment-artifacts-000000000000"
$roleBArn = "arn:aws:iam::${acct}:role/roleB"

$wildcardExceptions = @{
    'EcrAuthTokenRequiresWildcard'              = 'ecr:GetAuthorizationToken'
    'EcsRegisterTaskDefinitionRequiresWildcard' = 'ecs:RegisterTaskDefinition'
}

# Actions that must NOT appear in the ci policy (exact action names).
$excludedActions = @(
    'ecr:BatchDeleteImage', 'ecr:DeleteRepository', 'ecr:CreateRepository', 'ecr:SetRepositoryPolicy',
    'ecr:DeleteRepositoryPolicy', 'ecr:PutLifecyclePolicy', 'ecr:PutImageTagMutability', 'ecr:BatchGetImage',
    'ecs:CreateService', 'ecs:DeleteService', 'ecs:DeleteCluster', 'ecs:CreateCluster', 'ecs:RunTask', 'ecs:StartTask',
    'ecs:StopTask', 'ecs:DeregisterTaskDefinition', 'ecs:DescribeTaskDefinition', 'ecs:ExecuteCommand',
    's3:PutObject', 's3:DeleteObject', 's3:DeleteObjectVersion', 's3:PutBucketPolicy', 's3:DeleteBucket', 's3:PutObjectAcl',
    'iam:CreateUser', 'iam:CreateRole', 'iam:AttachUserPolicy', 'iam:AttachRolePolicy', 'iam:PutUserPolicy',
    'iam:PutRolePolicy', 'iam:CreateAccessKey', 'iam:UpdateAssumeRolePolicy',
    'sts:AssumeRole', 'ec2:RunInstances', 'ec2:TerminateInstances'
)

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

function As-List {
    # Leading comma keeps 1-element arrays intact for the caller.
    param($Value)
    if ($null -eq $Value) { return , @() }
    return , @($Value)
}

function Join-Sorted {
    # Flatten (string or array), sort, join. Binary -join binds LOOSER than -eq
    # in PowerShell, so always compare the result of this helper.
    param($Value)
    if ($null -eq $Value) { return '' }
    $flat = @($Value | ForEach-Object { $_ })
    return (($flat | Sort-Object) -join ',')
}

function Get-NormalizedPolicy {
    # Order-independent canonical text of a policy document.
    param($Doc)
    $lines = foreach ($s in (As-List $Doc.Statement)) {
        $actions = Join-Sorted $s.Action
        $notActions = Join-Sorted $s.NotAction
        $resources = Join-Sorted $s.Resource
        $cond = ''
        if ($null -ne $s.Condition) {
            $parts = foreach ($op in $s.Condition.PSObject.Properties) {
                foreach ($k in $op.Value.PSObject.Properties) {
                    '{0}:{1}={2}' -f $op.Name, $k.Name, (Join-Sorted $k.Value)
                }
            }
            $cond = (@($parts) | Sort-Object) -join ';'
        }
        '{0}|{1}|A={2}|NA={3}|R={4}|C={5}' -f $s.Sid, $s.Effect, $actions, $notActions, $resources, $cond
    }
    return ((@($lines) | Sort-Object) -join "`n")
}

$tempRoot = Join-Path $env:TEMP ("task4-poc-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    # ------------------------------------------------------------------
    Write-Step '1. Baseline: validate-local.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'validate-local.ps1') -PocLabel 'BASELINE' *>&1 |
        Select-String -Pattern '^(Repository structure|Required files|terraform (fmt|init|validate)|Secret/state check|Git repository)\s|BASELINE|missing' |
        ForEach-Object { Write-Host "  $_" }
    $results['Baseline: repo fmt/init/validate/hygiene'] = ($LASTEXITCODE -eq 0)

    # ------------------------------------------------------------------
    Write-Step '2. Offline plan of account-a (TEMP copy, mock credentials, no AWS calls)'
    $ws = New-OfflineWorkspace -RepoRoot $repoRoot -Stack 'account-a' -Destination (Join-Path $tempRoot 'offline')
    $pluginDir = Get-RepoPluginDir -RepoRoot $repoRoot -Stack 'account-a'
    $r = Invoke-Terraform @("-chdir=$ws", 'init', '-backend=false', '-input=false', '-no-color', "-plugin-dir=$pluginDir")
    $planFile = Join-Path $tempRoot 'account-a.tfplan'
    if ($r.Exit -eq 0) {
        $r = Invoke-Terraform @("-chdir=$ws", 'plan', '-refresh=false', '-input=false', '-no-color', '-var-file=terraform.tfvars.example', "-out=$planFile")
    }
    $summary = (($r.Text -split "`n" | Where-Object { $_ -match '^Plan:' }) -join '').Trim()
    if (-not (Write-Check 'account-a offline plan' ($r.Exit -eq 0) $summary)) {
        Write-Host $r.Text -ForegroundColor Red
        throw 'Offline plan failed - cannot continue.'
    }
    $plan = (& terraform "-chdir=$ws" show -json $planFile | Out-String | ConvertFrom-Json)
    $ciPolicyAfter = ($plan.resource_changes | Where-Object { $_.address -eq 'aws_iam_policy.ci' }).change.after
    $ciDoc = $ciPolicyAfter.policy | ConvertFrom-Json
    $roleBTrust = (($plan.resource_changes | Where-Object { $_.address -eq 'aws_iam_role.role_b' }).change.after.assume_role_policy) | ConvertFrom-Json
    $statements = As-List $ciDoc.Statement

    # ------------------------------------------------------------------
    Write-Step '3. Terraform policy structure'
    $ok = $true
    $ok = (Write-Check 'customer-managed policy "ci-least-privilege" planned' ($ciPolicyAfter.name -eq 'ci-least-privilege')) -and $ok
    $attach = $plan.resource_changes | Where-Object { $_.address -eq 'aws_iam_user_policy_attachment.ci' }
    $ok = (Write-Check 'attached to user ci' ($null -ne $attach -and $attach.change.after.user -eq 'ci')) -and $ok
    $cfgAttach = $plan.configuration.root_module.resources | Where-Object { $_.address -eq 'aws_iam_user_policy_attachment.ci' }
    $refs = @($cfgAttach.expressions.policy_arn.references)
    $ok = (Write-Check 'attachment references aws_iam_policy.ci (not a managed policy)' ($refs -contains 'aws_iam_policy.ci.arn')) -and $ok
    $otherAttach = @($plan.resource_changes | Where-Object {
            ($_.type -eq 'aws_iam_user_policy_attachment' -and $_.change.after.user -ne 'ci') -or
            ($_.type -eq 'aws_iam_group_policy_attachment') })
    $ok = (Write-Check 'not attached to group1 or engine (no other user/group attachments)' ($otherAttach.Count -eq 0)) -and $ok
    $results['Terraform policy structure'] = $ok

    # ------------------------------------------------------------------
    Write-Step '4. Rendered policy JSON'
    $ok = $true
    function Get-Statement { param([string]$Sid) return ($statements | Where-Object { $_.Sid -eq $Sid }) }

    $ecrPush = Get-Statement 'EcrPushToOneRepository'
    $expPush = 'ecr:BatchCheckLayerAvailability,ecr:CompleteLayerUpload,ecr:GetDownloadUrlForLayer,ecr:InitiateLayerUpload,ecr:PutImage,ecr:UploadLayerPart'
    $pushOk = ((Join-Sorted $ecrPush.Action) -eq $expPush) -and ((Join-Sorted $ecrPush.Resource) -eq $repoArn)
    $ok = (Write-Check 'ECR push: 6 push actions on exact repository ARN' $pushOk) -and $ok

    $ecs = Get-Statement 'EcsDeployOneService'
    $ecsOk = ((Join-Sorted $ecs.Action) -eq 'ecs:DescribeServices,ecs:UpdateService') -and ((Join-Sorted $ecs.Resource) -eq $serviceArn)
    $ok = (Write-Check 'ECS: UpdateService + DescribeServices on exact service ARN' $ecsOk) -and $ok

    $pass = Get-Statement 'PassOnlyEcsTaskRolesToEcsTasks'
    $passResOk = ((Join-Sorted $pass.Resource) -eq (Join-Sorted @($execRoleArn, $taskRoleArn))) -and ((Join-Sorted $pass.Action) -eq 'iam:PassRole')
    $ok = (Write-Check 'PassRole: exactly execution + task role ARNs' $passResOk) -and $ok
    $passSvc = Join-Sorted $pass.Condition.StringEquals.'iam:PassedToService'
    $ok = (Write-Check 'PassRole: iam:PassedToService = ecs-tasks.amazonaws.com' ($passSvc -eq 'ecs-tasks.amazonaws.com')) -and $ok

    $list = Get-Statement 'ListArtifactBucket'
    $get = Get-Statement 'ReadArtifactObjects'
    $listOk = ((Join-Sorted $list.Action) -eq 's3:ListBucket') -and ((Join-Sorted $list.Resource) -eq $bucketArn)
    $ok = (Write-Check 'S3: ListBucket on bucket ARN only' $listOk) -and $ok
    $getOk = ((Join-Sorted $get.Action) -eq 's3:GetObject') -and ((Join-Sorted $get.Resource) -eq "$bucketArn/*")
    $ok = (Write-Check 'S3: GetObject on bucket/* only (read-only)' $getOk) -and $ok
    $allAllow = ($statements.Count -eq 7) -and (@($statements | Where-Object { $_.Effect -ne 'Allow' }).Count -eq 0)
    $ok = (Write-Check 'exactly 7 statements, all Allow' $allAllow) -and $ok
    $refDoc = Get-Content -Raw (Join-Path $repoRoot 'policies\ci-policy.json') | ConvertFrom-Json
    $same = ((Get-NormalizedPolicy $ciDoc) -eq (Get-NormalizedPolicy $refDoc))
    $ok = (Write-Check 'rendered policy == policies/ci-policy.json (semantic)' $same) -and $ok
    $results['Rendered policy JSON (== policies/ci-policy.json)'] = $ok

    # ------------------------------------------------------------------
    Write-Step '5. Wildcard-resource exceptions reviewed'
    $ok = $true
    $starStatements = @($statements | Where-Object { (As-List $_.Resource) -contains '*' })
    $starSids = (@($starStatements | ForEach-Object { $_.Sid }) | Sort-Object) -join ','
    $ok = (Write-Check 'Resource "*" only in the 2 documented statements' ($starSids -eq ((@($wildcardExceptions.Keys) | Sort-Object) -join ',')) "($starSids)") -and $ok
    foreach ($st in $starStatements) {
        $acts = Join-Sorted $st.Action
        $single = ($acts -eq $wildcardExceptions[$st.Sid]) -and ((As-List $st.Resource).Count -eq 1)
        $ok = (Write-Check "  $($st.Sid): only $($wildcardExceptions[$st.Sid])" $single) -and $ok
    }
    $actionWildcards = @($statements | ForEach-Object { As-List $_.Action } | ForEach-Object { $_ } | Where-Object { $_ -match '\*' })
    $ok = (Write-Check 'no action wildcards (e.g. ecr:*, s3:*, ecs:*)' ($actionWildcards.Count -eq 0)) -and $ok
    $partialStar = @($statements | ForEach-Object { As-List $_.Resource } | ForEach-Object { $_ } | Where-Object { $_ -ne '*' -and $_ -match '\*' -and $_ -ne "$bucketArn/*" })
    $ok = (Write-Check 'no partial-wildcard ARNs except artifact bucket/*' ($partialStar.Count -eq 0)) -and $ok
    $notForms = @($statements | Where-Object { $null -ne $_.NotAction -or $null -ne $_.NotResource })
    $ok = (Write-Check 'no NotAction / NotResource' ($notForms.Count -eq 0)) -and $ok
    $results['Wildcard-resource exceptions reviewed'] = $ok

    # ------------------------------------------------------------------
    Write-Step '6. Broad managed policies absent'
    $broadPattern = 'AdministratorAccess|PowerUserAccess|FullAccess|AmazonEC2ContainerRegistryPowerUser|AmazonECS_FullAccess'
    $arns = @($plan.resource_changes | Where-Object { $_.type -match 'policy_attachment' } | ForEach-Object { $_.change.after.policy_arn } | Where-Object { $_ })
    $cfgArns = @($plan.configuration.root_module.resources | Where-Object { $_.type -match 'policy_attachment' } | ForEach-Object { $_.expressions.policy_arn.constant_value } | Where-Object { $_ })
    $broad = @(($arns + $cfgArns) | Where-Object { $_ -match $broadPattern })
    $results['Broad managed policies absent'] = (Write-Check 'no AdministratorAccess / PowerUserAccess / *FullAccess / ECR PowerUser attached' ($broad.Count -eq 0))

    # ------------------------------------------------------------------
    Write-Step '7. Deliberately excluded actions absent'
    $granted = @($statements | ForEach-Object { As-List $_.Action } | ForEach-Object { $_ })
    $present = @($excludedActions | Where-Object { $granted -contains $_ })
    $results['Excluded actions absent'] = (Write-Check "$($excludedActions.Count) excluded actions not granted" ($present.Count -eq 0) "(present: $($present -join ', '))")
    $otherIam = @($granted | Where-Object { $_ -like 'iam:*' -and $_ -ne 'iam:PassRole' })
    $results['Excluded actions absent'] = (Write-Check 'no IAM action other than scoped iam:PassRole' ($otherIam.Count -eq 0)) -and $results['Excluded actions absent']

    # ------------------------------------------------------------------
    Write-Step '8. Access matrix A-Q - simplified IAM model on the rendered policy (NOT AWS)'
    $ciPolicies = @($ciDoc)
    $m = $true
    function Test-Ci {
        param([string]$Id, [string]$Action, [string]$Resource, [bool]$Expect, [hashtable]$Keys = @{})
        $ctx = @{ Username = 'ci' }
        if ($Keys.Count -gt 0) { $ctx['ConditionKeys'] = $Keys }
        $d = Get-IdentityDecision -Policies $ciPolicies -Action $Action -Resource $Resource -Context $ctx
        $verdict = 'DENY'
        if ($d -eq 'Allow') { $verdict = 'ALLOW' }
        $exp = 'DENY'
        if ($Expect) { $exp = 'ALLOW' }
        return (Write-Check ("{0,-2} {1} {2}" -f $Id, $Action, $Resource) (($d -eq 'Allow') -eq $Expect) "=> $verdict (expected $exp)")
    }
    $ecsTasks = @{ 'iam:PassedToService' = 'ecs-tasks.amazonaws.com' }

    $m = (Test-Ci 'A' 'ecr:GetAuthorizationToken' '*' $true) -and $m
    foreach ($a in @('ecr:BatchCheckLayerAvailability', 'ecr:InitiateLayerUpload', 'ecr:UploadLayerPart', 'ecr:CompleteLayerUpload', 'ecr:PutImage', 'ecr:GetDownloadUrlForLayer')) {
        $m = (Test-Ci 'B' $a $repoArn $true) -and $m
    }
    $m = (Test-Ci 'C' 'ecr:PutImage' $otherRepoArn $false) -and $m
    $m = (Test-Ci 'C' 'ecr:InitiateLayerUpload' $otherRepoArn $false) -and $m
    $m = (Test-Ci 'D' 'ecr:BatchDeleteImage' $repoArn $false) -and $m
    $m = (Test-Ci 'D' 'ecr:DeleteRepository' $repoArn $false) -and $m
    $m = (Test-Ci 'D' 'ecr:SetRepositoryPolicy' $repoArn $false) -and $m
    $m = (Test-Ci 'E' 'ecs:RegisterTaskDefinition' '*' $true) -and $m
    $m = (Test-Ci 'F' 'ecs:UpdateService' $serviceArn $true) -and $m
    $m = (Test-Ci 'F' 'ecs:DescribeServices' $serviceArn $true) -and $m
    $m = (Test-Ci 'G' 'ecs:UpdateService' $otherServiceArn $false) -and $m
    $m = (Test-Ci 'G' 'ecs:UpdateService' $otherClusterServiceArn $false) -and $m
    $m = (Test-Ci 'G' 'ecs:CreateService' '*' $false) -and $m
    $m = (Test-Ci 'G' 'ecs:DeleteService' $serviceArn $false) -and $m
    $m = (Test-Ci 'G' 'ecs:RunTask' '*' $false) -and $m
    $m = (Test-Ci 'H' 'iam:PassRole' $execRoleArn $true $ecsTasks) -and $m
    $m = (Test-Ci 'I' 'iam:PassRole' $taskRoleArn $true $ecsTasks) -and $m
    $m = (Test-Ci 'J' 'iam:PassRole' "arn:aws:iam::${acct}:role/roleA" $false $ecsTasks) -and $m
    $m = (Test-Ci 'J' 'iam:PassRole' "arn:aws:iam::${acct}:role/some-admin-role" $false $ecsTasks) -and $m
    $m = (Test-Ci 'K' 'iam:PassRole' $execRoleArn $false @{ 'iam:PassedToService' = 'lambda.amazonaws.com' }) -and $m
    $m = (Test-Ci 'K' 'iam:PassRole' $taskRoleArn $false @{ 'iam:PassedToService' = 'ec2.amazonaws.com' }) -and $m
    $m = (Test-Ci 'K' 'iam:PassRole' $execRoleArn $false) -and $m
    $m = (Test-Ci 'L' 's3:ListBucket' $bucketArn $true) -and $m
    $m = (Test-Ci 'M' 's3:GetObject' "$bucketArn/builds/app-1.2.3.zip" $true) -and $m
    $m = (Test-Ci 'N' 's3:PutObject' "$bucketArn/builds/app-1.2.3.zip" $false) -and $m
    $m = (Test-Ci 'N' 's3:DeleteObject' "$bucketArn/builds/app-1.2.3.zip" $false) -and $m
    $m = (Test-Ci 'N' 's3:PutBucketPolicy' $bucketArn $false) -and $m
    $m = (Test-Ci 'O' 's3:GetObject' 'arn:aws:s3:::some-other-bucket/secret.txt' $false) -and $m
    $m = (Test-Ci 'O' 's3:ListBucket' 'arn:aws:s3:::some-other-bucket' $false) -and $m
    $m = (Test-Ci 'O' 's3:GetObject' 'arn:aws:s3:::aws-terraform-devops-assignment-crossacct-111111111111/x' $false) -and $m
    $p = Test-AssumeRole -CallerArn "arn:aws:iam::${acct}:user/ci" -CallerPolicies $ciPolicies -TargetRoleArn $roleBArn -TargetTrustPolicy $roleBTrust -Context @{ Username = 'ci' }
    $m = (Write-Check 'P  ci -> sts:AssumeRole roleB' (-not $p.Allowed) "=> DENY (identity=$($p.Identity), trust=$($p.Trust))") -and $m
    foreach ($a in @(@('iam:CreateUser', '*'), @('iam:AttachUserPolicy', "arn:aws:iam::${acct}:user/ci"), @('iam:CreateAccessKey', "arn:aws:iam::${acct}:user/ci"), @('iam:PutUserPolicy', "arn:aws:iam::${acct}:user/ci"), @('ec2:RunInstances', '*'), @('ec2:TerminateInstances', '*'))) {
        $m = (Test-Ci 'Q' $a[0] $a[1] $false) -and $m
    }
    $results['Least-privilege access matrix A-Q (model, not AWS)'] = $m

    # ------------------------------------------------------------------
    Write-Step '9. Negative inputs (wildcard targets must be rejected)'
    $negOk = $true
    $negCases = [ordered]@{
        'invalid-wildcard-ecr-repository.vars.hcl'  = 'ci_ecr_repository_name must be a valid ECR repository name'
        'invalid-wildcard-ecs-service.vars.hcl'     = 'ci_ecs_service_name must be 1-255 letters'
        'invalid-wildcard-passrole.vars.hcl'        = 'ci_ecs_task_role_name must be a valid IAM role name'
        'invalid-wildcard-artifact-bucket.vars.hcl' = 'ci_artifact_bucket_name must be a valid S3 bucket name'
    }
    foreach ($fixture in $negCases.Keys) {
        $fixturePath = Join-Path $repoRoot "tests\fixtures\task4\$fixture"
        $r = Invoke-Terraform @("-chdir=$ws", 'plan', '-refresh=false', '-input=false', '-no-color', '-var-file=terraform.tfvars.example', "-var-file=$fixturePath")
        $ok = ($r.Exit -ne 0) -and (($r.Text -replace '\s+', ' ') -like "*$($negCases[$fixture])*")
        $negOk = (Write-Check $fixture $ok) -and $negOk
    }
    $results['Wildcard CI targets rejected'] = $negOk
}
catch {
    Write-Host "  ERROR: $_" -ForegroundColor Red
}
finally {
    $cleanupOk = Remove-TempWorkspace -Path $tempRoot
}

# ----------------------------------------------------------------------
Write-Host ''
Write-Host '==================== TASK 4 LOCAL POC SUMMARY ====================' -ForegroundColor Cyan
$expectedChecks = 8
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
    Write-Host "POC-4 (LOCAL): PASS  ($($results.Count)/$expectedChecks checks; no AWS resources were created)" -ForegroundColor Green
}
else {
    Write-Host "POC-4 (LOCAL): FAIL  ($($results.Count)/$expectedChecks checks ran)" -ForegroundColor Red
}
Write-Host ''
Write-Host 'REAL AWS POC' -ForegroundColor Yellow
foreach ($line in @('Actual ECR push', 'Actual ECS task registration', 'Actual ECS service deployment', 'Actual iam:PassRole', 'Actual S3 artifact read', 'Negative AWS authorization tests')) {
    Write-Host ('{0,-56} {1}' -f $line, 'PENDING') -ForegroundColor Yellow
}

if ($allPassed) { exit 0 }
exit 1
