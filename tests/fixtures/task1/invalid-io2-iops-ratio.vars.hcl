# NEGATIVE: io2 allows at most 1000 IOPS per GiB. 60000 IOPS on 50 GiB exceeds 50000.
# Expected: "root_volume_iops out of range"
ami_id = "ami-0123456789abcdef0"

instances = {
  web03 = {
    instance_type    = "t3.medium"
    root_volume_type = "io2"
    root_volume_size = 50
    root_volume_iops = 60000
    key_name         = "web03-key"
    protected        = true
  }
}
