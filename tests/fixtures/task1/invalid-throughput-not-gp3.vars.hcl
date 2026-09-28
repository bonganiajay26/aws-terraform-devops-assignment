# NEGATIVE: throughput can only be provisioned on gp3.
# Expected: "root_volume_throughput is only valid for gp3"
ami_id = "ami-0123456789abcdef0"

instances = {
  web03 = {
    instance_type          = "t3.medium"
    root_volume_type       = "io2"
    root_volume_size       = 50
    root_volume_iops       = 3000
    root_volume_throughput = 250
    key_name               = "web03-key"
    protected              = true
  }
}
