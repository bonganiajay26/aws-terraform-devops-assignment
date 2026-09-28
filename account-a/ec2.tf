# Task 1 - five EC2 instances, all driven by var.instances (see terraform.tfvars.example).
module "ec2" {
  source = "../modules/ec2"

  ami_id                 = var.ami_id
  instances              = var.instances
  environment            = var.environment
  owner                  = var.owner
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.vpc_security_group_ids
}
