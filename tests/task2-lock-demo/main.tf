# -----------------------------------------------------------------------------
# LOCAL MECHANISM DEMO - NOT AWS EVIDENCE
#
# Terraform locks state before any write, whatever the backend. This config
# uses the LOCAL backend (file lock on terraform.tfstate) so the behaviour can
# be shown without AWS. The S3 backend does the same thing with a DynamoDB item
# (LockID = "<bucket>/<key>"). Run by scripts/task2-local-poc.ps1 in a TEMP copy:
#   process 1: terraform apply  -> holds the lock ~20 s (local-exec sleep)
#   process 2: terraform plan   -> "Error acquiring the state lock"
#   after process 1 ends        -> a new operation acquires the lock
#
# Windows limitation: the local backend's byte-range file lock makes process 2
# fail immediately (file read error), so -lock-timeout waiting cannot be shown
# here. The S3 backend retries the DynamoDB conditional write until
# -lock-timeout expires - verified in the REAL AWS POC (tests/task2-test.md R6).
# The local-exec interpreter is PowerShell, so this demo is Windows-only.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0, < 2.0.0"
}

variable "hold_seconds" {
  description = "How long the apply keeps the state lock."
  type        = number
  default     = 20
}

resource "terraform_data" "long_running_change" {
  input = "simulated long-running infrastructure change"

  provisioner "local-exec" {
    interpreter = ["powershell", "-NoProfile", "-Command"]
    command     = "Start-Sleep -Seconds ${var.hold_seconds}"
  }
}
