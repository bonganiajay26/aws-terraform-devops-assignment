# Troubleshooting

## Task 0

| Symptom | Cause | Fix |
|---|---|---|
| `terraform : The term 'terraform' is not recognized` | Not installed or PATH not refreshed | `winget install --id HashiCorp.Terraform -e`, then open a NEW PowerShell window |
| `... cannot be loaded because running scripts is disabled` | Execution policy | `Set-ExecutionPolicy -Scope Process Bypass` (current window only) |
| `terraform fmt -check` lists files you did not change | CRLF line endings from a Windows editor | Run `terraform fmt -recursive`; set VS Code to LF; `.gitattributes` normalises on commit |
| `Failed to query available provider packages` | No internet / corporate proxy | Set `$env:HTTPS_PROXY` or use a network that reaches registry.terraform.io |
| `The filename or extension is too long` during init | Windows 260-character path limit | Keep the repo at a short path such as `C:\work\aws-terraform-devops-assignment` |
| `Unsupported Terraform Core version` or `too old` | Local Terraform < 1.5 | Chocolatey install: `choco upgrade terraform -y` (Administrator). winget install: `winget upgrade --id HashiCorp.Terraform`. Check with `Get-Command terraform -All` that only one terraform.exe is on PATH |
| `Author identity unknown` on commit | Git user not configured | `git config --global user.name "Your Name"` and `git config --global user.email "you@example.com"` |
| CI `secret-hygiene` fails | Forbidden file committed | `git rm --cached <file>`, commit, and ROTATE any exposed credential |

## Task 1

| Symptom | Cause | Fix |
|---|---|---|
| `Error: Variables not allowed` on `prevent_destroy` | Lifecycle values must be literals | Use the two-block split in `modules/ec2/main.tf`; never `each.value.*` in `lifecycle` |
| `Error: Instance cannot be destroyed` | Plan destroys/replaces `aws_instance.protected[...]` | Intended. Check why: removed from map, or a replacement-forcing change (AMI, key_name, subnet). To remove deliberately see `tests/task1-test.md` section 3 |
| `Error: Module not installed` | `ec2.tf` added after the last init | `terraform -chdir=account-a init -backend=false` |
| `No value for required variable "ami_id"` / `"instances"` | No tfvars passed | `Copy-Item terraform.tfvars.example terraform.tfvars` and edit, or `-var-file=terraform.tfvars.example` for a local plan |
| `Error: Too many command line arguments` in PowerShell | PS 5.1 splits unquoted args like `-var-file=x.tfvars` at the dot | Quote them: `'-var-file=terraform.tfvars.example'` |
| `InvalidAMIID.NotFound` (real AWS) | AMI from another region / placeholder AMI | Look up the AMI in the provider region (README Task 1) |
| `InvalidKeyPair.NotFound` (real AWS) | Key pair missing in the region | Create web01..05-key (`tests/task1-test.md`) |
| `InvalidParameterCombination ... iops` (real AWS) | IOPS on gp2 or ratio exceeded | Validation normally catches this at plan; check the limits table in README |
| `VcpuLimitExceeded` / `InsufficientInstanceCapacity` (real AWS) | New-account vCPU quota (t3.xlarge = 4 vCPU) | Request a quota increase or use smaller types for the POC |
| `No default VPC for this user` (real AWS) | Default VPC deleted | Set `subnet_id` and `vpc_security_group_ids` in `terraform.tfvars` |
| `OperationNotPermitted` terminating web03 in console | `disable_api_termination = true` | Intended. Follow the cleanup procedure |
