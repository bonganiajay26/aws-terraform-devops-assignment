# NEGATIVE: gp2 IOPS are derived from size and cannot be provisioned.
# Expected: "must not be set for gp2"
ami_id = "ami-0123456789abcdef0"

instances = {
  web02 = {
    instance_type    = "t3.small"
    root_volume_type = "gp2"
    root_volume_size = 30
    root_volume_iops = 3000
    key_name         = "web02-key"
    protected        = true
  }
}
