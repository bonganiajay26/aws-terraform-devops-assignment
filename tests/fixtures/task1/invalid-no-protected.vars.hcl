# NEGATIVE: assignment requires one protected (critical) instance.
# Expected: "At least one instance must set protected = true"
ami_id = "ami-0123456789abcdef0"

instances = {
  web01 = {
    instance_type    = "t3.micro"
    root_volume_type = "gp3"
    root_volume_size = 20
    key_name         = "web01-key"
  }
}
