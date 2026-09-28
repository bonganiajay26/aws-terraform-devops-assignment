# NEGATIVE: malformed AMI ID.
# Expected: "ami_id must look like ami-xxxxxxxx"
ami_id = "ami-123"

instances = {
  web01 = {
    instance_type    = "t3.micro"
    root_volume_type = "gp3"
    root_volume_size = 20
    key_name         = "web01-key"
    protected        = true
  }
}
