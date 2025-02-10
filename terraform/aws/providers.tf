terraform {
  required_version = ">= v1.10.1"
  required_providers {
    aws = {
      version = ">= 5.80.0"
      source  = "hashicorp/aws"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.34.0"
    }
  }
  backend "s3" {
    key = "eks-hybrid/aws.tfstate"
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = {
      GithubOrg  = "yomon8"
      GithubRepo = "eks-hybrid"
    }
  }
}