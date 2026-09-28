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
