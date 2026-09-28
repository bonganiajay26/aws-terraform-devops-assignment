# NEGATIVE: io1/io2 require provisioned IOPS.
# Expected: "root_volume_iops is required for io1/io2"
ami_id = "ami-0123456789abcdef0"

instances = {
  web05 = {
    instance_type    = "t3.xlarge"
    root_volume_type = "io1"
    root_volume_size = 100
    key_name         = "web05-key"
    protected        = true
  }
}
