terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  # Modules declare WHICH provider they need; the calling root module
  # configures it (region, credentials, default_tags).
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}
