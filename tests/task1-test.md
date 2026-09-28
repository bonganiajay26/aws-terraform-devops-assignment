# Task 1 - Multi-instance EC2 - Test Procedure

Two phases, never mixed:

- **Phase 1 - LOCAL** (done, no AWS account): `scripts/task1-local-poc.ps1`
- **Phase 2 - REAL AWS** (pending an account): the commands in section 2

---

## 1. LOCAL POC (no AWS)

```powershell
Set-Location C:\work\aws-terraform-devops-assignment
powershell -ExecutionPolicy Bypass -File .\scripts\task1-local-poc.ps1
```

| # | Check | How | Expected |
|---|---|---|---|
| L1 | Baseline | `validate-local.ps1` | fmt / init / validate / hygiene PASS |
| L2 | Invalid design rejected | temp config with `prevent_destroy = each.value.protected` | Terraform refuses it (non-zero exit) |
| L3 | 5 instances from one variable | offline plan of `account-a` with `terraform.tfvars.example` | `Plan: 5 to add` |
| L4 | Per-instance config | plan JSON | type, volume type/size/IOPS/throughput, key pair, Name/Environment/Owner exactly as specified |
| L5 | io1/io2 present | plan JSON | web03 io2, web05 io1 |
| L6 | Protection wiring | plan JSON | web03 at `aws_instance.protected["web03"]`, `disable_api_termination = true`; others `false` |
| L7 | Outputs | plan JSON | `instance_ids` and `private_ips` keyed web01..web05 (values known after apply) |
| L8 | Negative inputs | 7 fixtures in `tests/fixtures/task1/` | each rejected with its specific validation message |
| L9 | prevent_destroy mechanism | `tests/task1-prevent-destroy-demo` (terraform_data, TEMP state) | unprotected removal = destroy planned; protected removal and `terraform destroy` = `Instance cannot be destroyed` |

**Offline plan:** `scripts/OfflineWorkspace.psm1` copies `account-a` and `modules/`
into a TEMP folder, removes `backend.tf`, and adds an `offline_override.tf` there with
mock credentials and `skip_*` flags. It then initialises from the repo's already
downloaded providers (`-plugin-dir`), so `terraform plan` runs with zero AWS API calls
and nothing is ever written inside the repository. The TEMP folder is deleted at the
end. This proves the Terraform logic. It does NOT prove AWS accepts the values.

**prevent_destroy demo:** uses `terraform_data` because testing against real EC2
state needs an AWS account. The lifecycle mechanism is identical; EC2-specific
evidence is test R6 below.

### Local evidence

```
Date: 2026-09-28   Terraform: v1.5.4   hashicorp/aws: v6.66.0

Baseline (fmt/init/validate/hygiene)             PASS
Dynamic prevent_destroy rejected                 PASS
Offline plan: 5 instances as specified           PASS
Invalid volume/AMI/protection inputs rejected    PASS
prevent_destroy blocks protected destroy         PASS

POC-1 (LOCAL): PASS
```

---

## 2. REAL AWS POC (pending - requires Account A)

> Costs money: t3.xlarge/t3.large plus io1/io2 provisioned IOPS are billed per hour.
> Run, collect evidence, then clean up (section 3) the same day.

### Prerequisites

```powershell
aws sts get-caller-identity
$region = 'us-east-1'
aws ssm get-parameter --region $region --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text
```

Create the five key pairs (the private keys are saved locally and git-ignored by `*.pem`):

```powershell
New-Item -ItemType Directory -Force -Path $HOME\.ssh\assignment | Out-Null
foreach ($k in 'web01-key','web02-key','web03-key','web04-key','web05-key') {
    aws ec2 create-key-pair --region $region --key-name $k --key-type ed25519 --query KeyMaterial --output text | Out-File -Encoding ascii "$HOME\.ssh\assignment\$k.pem"
}
aws ec2 describe-key-pairs --region $region --query "KeyPairs[].KeyName"
```

Create `account-a/terraform.tfvars` from the example: set the real `account_a_id`
and the real `ami_id`.

### R1 - plan / apply

```powershell
Set-Location C:\work\aws-terraform-devops-assignment\account-a
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

Expected: `Apply complete! Resources: 5 added, 0 changed, 0 destroyed.`

### R2 - instances, types, key pairs, tags

```powershell
aws ec2 describe-instances --region $region --filters "Name=tag:Project,Values=aws-terraform-devops-assignment" "Name=instance-state-name,Values=pending,running" --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,Id:InstanceId,Type:InstanceType,Key:KeyName,Env:Tags[?Key=='Environment']|[0].Value,Owner:Tags[?Key=='Owner']|[0].Value,PrivateIp:PrivateIpAddress}" --output table
```

Expected: 5 rows, types t3.micro/small/medium/large/xlarge, keys web01..05-key,
Environment dev (web03 = prod), Owner platform-team.

### R3 - root volumes

```powershell
aws ec2 describe-volumes --region $region --filters "Name=tag:Project,Values=aws-terraform-devops-assignment" --query "Volumes[].{Name:Tags[?Key=='Name']|[0].Value,Type:VolumeType,Size:Size,Iops:Iops,Throughput:Throughput,Encrypted:Encrypted}" --output table
```

Expected: web01 gp3/20, web02 gp2/30, web03 io2/50/3000, web04 gp3/80/6000/250, web05 io1/100/4000; all encrypted.

### R4 - outputs

```powershell
terraform output instance_ids
terraform output private_ips
terraform output protected_instance_names
```

Expected: maps keyed web01..web05 with `i-...` IDs and `172.31.x.x` (default VPC) IPs; `["web03"]`.

### R5 - AWS-side termination protection

```powershell
$id = (terraform output -json instance_ids | ConvertFrom-Json).web03
aws ec2 describe-instance-attribute --region $region --instance-id $id --attribute disableApiTermination
aws ec2 terminate-instances --region $region --instance-ids $id
```

Expected: `"Value": true`, then `OperationNotPermitted ... may not be terminated`.

### R6 - NEGATIVE: Terraform refuses to destroy web03

Remove the `web03 = { ... }` block from `terraform.tfvars` (or change its
`key_name`, which forces replacement), then:

```powershell
terraform plan
terraform destroy
```

Expected (both):

```
Error: Instance cannot be destroyed
  on ..\modules\ec2\main.tf ... resource "aws_instance" "protected"
Resource module.ec2.aws_instance.protected["web03"] has lifecycle.prevent_destroy set,
but the plan calls for this resource to be destroyed.
```

Restore `terraform.tfvars`. Nothing was changed in AWS.

### R7 - POSITIVE: unprotected instance can be removed

Remove `web01` from `terraform.tfvars` and run `terraform plan`. Expected:
`Plan: 0 to add, 0 to change, 1 to destroy.` Do not apply; restore the file.

### Real-AWS evidence

```
Date:
Account (last 4 digits only):
R1 apply            :
R2 instances/tags   :
R3 volumes          :
R4 outputs          :
R5 termination prot.:
R6 prevent_destroy  :
R7 unprotected      :
POC-1 (REAL AWS)    :
```

---

## 3. Cleanup (real AWS)

`terraform destroy` is blocked by design for web03. Deliberate removal:

1. Move web03 to the standard group WITHOUT destroying it: set
   `protected = false` for web03 in `terraform.tfvars` and temporarily add to `account-a/ec2.tf`:
   ```hcl
   moved {
     from = module.ec2.aws_instance.protected["web03"]
     to   = module.ec2.aws_instance.standard["web03"]
   }
   ```
2. `terraform apply`: moves the state address and sets `disable_api_termination = false` (0 destroyed).
3. `terraform destroy`: removes all 5 instances.
4. Delete the key pairs: `aws ec2 delete-key-pair --key-name web0N-key` (x5), and the local `.pem` files.
5. Remove the temporary `moved` block and restore `protected = true`.
