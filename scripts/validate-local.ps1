<#
.SYNOPSIS
    Local equivalent of .github/workflows/terraform-validate.yml (Windows PowerShell 5.1+).
.DESCRIPTION
    Checks, in order:
      1. Repository structure   - required folders exist
      2. Required files         - required files exist
      3. terraform fmt          - terraform fmt -check -recursive
      4. terraform init         - init -backend=false for every root module
      5. terraform validate     - validate for every root module
      6. Secret/state check     - no forbidden files or credential patterns
                                  in tracked OR about-to-be-added files
      7. Git repository         - the folder is a Git work tree
    Never calls AWS. Internet is needed only to download the AWS provider on first init.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\validate-local.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Stacks = @('bootstrap', 'account-a', 'account-b'),
    [string]$PocLabel = 'POC-0'
)

# Native-command failures are handled through $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$results = [ordered]@{}

$requiredDirectories = @(
    'docs', 'bootstrap', 'modules/ec2', 'account-a', 'account-b',
    'policies', 'tests', 'scripts', '.github/workflows'
)

$requiredFiles = @(
    '.gitignore', '.gitattributes', '.editorconfig', 'README.md', 'NOTES.md',
    'docs/architecture.md', 'docs/testing.md', 'docs/troubleshooting.md',
    'bootstrap/versions.tf', 'bootstrap/providers.tf', 'bootstrap/variables.tf', 'bootstrap/terraform.tfvars.example',
    'account-a/versions.tf', 'account-a/providers.tf', 'account-a/variables.tf', 'account-a/terraform.tfvars.example',
    'account-b/versions.tf', 'account-b/providers.tf', 'account-b/variables.tf', 'account-b/terraform.tfvars.example',
    '.github/workflows/terraform-validate.yml', 'scripts/validate-local.ps1', 'tests/task0-test.md',
    # Task 1
    'modules/ec2/versions.tf', 'modules/ec2/main.tf', 'modules/ec2/variables.tf', 'modules/ec2/outputs.tf',
    'account-a/ec2.tf', 'account-a/outputs.tf', 'scripts/task1-local-poc.ps1', 'tests/task1-test.md',
    'tests/task1-prevent-destroy-demo/main.tf', 'scripts/OfflineWorkspace.psm1',
    # Task 2
    'bootstrap/main.tf', 'bootstrap/outputs.tf',
    'account-a/backend.tf', 'account-a/backend.hcl.example',
    'account-b/backend.tf', 'account-b/backend.hcl.example',
    'scripts/task2-local-poc.ps1', 'tests/task2-test.md', 'tests/task2-lock-demo/main.tf',
    # Task 3
    'account-a/iam-users-groups.tf', 'account-a/role-a.tf', 'account-a/role-b.tf',
    'account-b/s3.tf', 'account-b/role-c.tf', 'account-b/outputs.tf',
    'scripts/IamPolicyModel.psm1', 'scripts/task3-local-poc.ps1', 'tests/task3-test.md'
)

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    Write-Host 'terraform.exe not found on PATH. Run: winget install --id HashiCorp.Terraform -e  (then reopen PowerShell)' -ForegroundColor Red
    exit 1
}

Push-Location $repoRoot
try {
    Write-Step 'terraform version'
    terraform version

    # 1. Repository structure
    Write-Step 'Repository structure'
    $missingDirs = @($requiredDirectories | Where-Object { -not (Test-Path -PathType Container (Join-Path $repoRoot $_)) })
    $missingDirs | ForEach-Object { Write-Host "  missing folder: $_" -ForegroundColor Red }
    $results['Repository structure'] = ($missingDirs.Count -eq 0)

    # 2. Required files
    Write-Step 'Required files'
    $missingFiles = @($requiredFiles | Where-Object { -not (Test-Path -PathType Leaf (Join-Path $repoRoot $_)) })
    $missingFiles | ForEach-Object { Write-Host "  missing file: $_" -ForegroundColor Red }
    $results['Required files'] = ($missingFiles.Count -eq 0)

    # 3. terraform fmt
    Write-Step 'terraform fmt -check -recursive'
    terraform fmt -check -recursive -diff
    $results['terraform fmt'] = ($LASTEXITCODE -eq 0)

    # 4 + 5. terraform init / validate per root module
    $initOk = $true
    $validateOk = $true
    foreach ($stack in $Stacks) {
        if (-not (Test-Path -PathType Container (Join-Path $repoRoot $stack))) {
            Write-Host "  stack folder not found: $stack" -ForegroundColor Red
            $initOk = $false
            $validateOk = $false
            continue
        }

        Write-Step "terraform init -backend=false ($stack)"
        terraform "-chdir=$stack" init -backend=false -input=false -no-color
        if ($LASTEXITCODE -ne 0) {
            $initOk = $false
            $validateOk = $false
            continue
        }

        Write-Step "terraform validate ($stack)"
        terraform "-chdir=$stack" validate -no-color
        if ($LASTEXITCODE -ne 0) { $validateOk = $false }
    }
    $results['terraform init'] = $initOk
    $results['terraform validate'] = $validateOk

    # 6 + 7. Git repository and secret/state hygiene
    Write-Step 'Git repository and secret/state check'
    $isGitRepo = $false
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $inside = git rev-parse --is-inside-work-tree 2>$null
        $isGitRepo = ($LASTEXITCODE -eq 0 -and "$inside".Trim() -eq 'true')
    }
    $results['Git repository'] = $isGitRepo

    if ($isGitRepo) {
        $secretOk = $true

        # Tracked files PLUS untracked files that `git add .` would pick up.
        $candidates = @(git ls-files --cached --others --exclude-standard)
        $forbidden = '(^|/)\.terraform/|\.tfstate($|\.)|\.tfplan$|(^|/)terraform\.tfvars(\.json)?$|\.pem$|\.key$|(^|/)\.env$'
        $badFiles = @($candidates | Where-Object { $_ -match $forbidden })
        if ($badFiles.Count -gt 0) {
            Write-Host '  Forbidden files would be committed:' -ForegroundColor Red
            $badFiles | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            $secretOk = $false
        }
        else {
            Write-Host "  $($candidates.Count) committable files checked - no forbidden files." -ForegroundColor Green
        }

        $patterns = @('(AKIA|ASIA)[0-9A-Z]{16}', 'BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY')
        foreach ($pattern in $patterns) {
            $hits = @(git grep --untracked -nE $pattern -- . 2>$null)
            $grepExit = $LASTEXITCODE
            if ($grepExit -eq 0) {
                Write-Host "  Credential pattern found ($pattern):" -ForegroundColor Red
                $hits | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
                $secretOk = $false
            }
            elseif ($grepExit -gt 1) {
                Write-Host "  git grep failed (exit $grepExit) - cannot confirm absence of secrets." -ForegroundColor Red
                $secretOk = $false
            }
        }
        if ($secretOk) {
            Write-Host '  No credential patterns found.' -ForegroundColor Green
        }
        $results['Secret/state check'] = $secretOk
    }
    else {
        Write-Host '  Not a Git work tree - run: git init' -ForegroundColor Red
        $results['Secret/state check'] = $false
    }
}
finally {
    Pop-Location
}

# Summary (order matches the POC evidence format)
$order = @('Repository structure', 'Required files', 'terraform fmt', 'terraform init', 'terraform validate', 'Secret/state check', 'Git repository')
Write-Host ''
Write-Host '==================== SUMMARY ====================' -ForegroundColor Cyan
$allPassed = $true
foreach ($name in $order) {
    $passed = [bool]$results[$name]
    if (-not $passed) { $allPassed = $false }
    $label = 'FAIL'
    $color = 'Red'
    if ($passed) {
        $label = 'PASS'
        $color = 'Green'
    }
    Write-Host ('{0,-24} {1}' -f $name, $label) -ForegroundColor $color
}
Write-Host ''
if ($allPassed) {
    Write-Host "${PocLabel}: PASS  (local validation only - nothing was deployed to AWS)" -ForegroundColor Green
    exit 0
}
Write-Host "${PocLabel}: FAIL" -ForegroundColor Red
exit 1
