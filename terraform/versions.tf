terraform {
  required_version = ">= 1.5.0"

  # Remote state: OpenStack Swift via S3-compatible API — copy
  # backend.swift-s3.hcl.example → backend.hcl, add `backend "s3" {}` here, then
  # `terraform init -backend-config=backend.hcl`. Native `backend "swift"` was
  # removed in Terraform 1.3; see README § Terraform state.
  #
  backend "s3" {}

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.54"
    }
  }
}

provider "openstack" {
  # Auth via OS_* environment variables (application credential in CI).
}
