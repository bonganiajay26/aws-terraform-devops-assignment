# NEGATIVE: st1 (throughput HDD) cannot be a boot volume.
# Expected: "root_volume_type must be one of gp2, gp3, io1, io2"
ami_id = "ami-0123456789abcdef0"

instances = {
  web01 = {
    instance_type    = "t3.micro"
    root_volume_type = "st1"
    root_volume_size = 125
    key_name         = "web01-key"
    protected        = true
  }
}
