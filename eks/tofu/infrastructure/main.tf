terraform {
  backend "s3" {
    use_lockfile = true
  }
  required_providers {
    aws = {
      version = ">=6.0"
    }
  }
}

locals {
  cluster1_name   = "ha1"
  cluster1_region = "us-east-1"
  cluster2_region = "us-east-2"
  cluster2_name   = "ha2"
  eks_version     = "1.36"

  cluster1_cidr = "10.0.0.0/16"
  cluster2_cidr = "10.1.0.0/16"

  cluster1_private_subnets = [for k, v in [0, 1] : cidrsubnet(local.cluster1_cidr, 4, k)]
  cluster1_public_subnets  = [for k, v in [0, 1] : cidrsubnet(local.cluster1_cidr, 8, k + 48)]

  cluster2_private_subnets = [for k, v in [0, 2] : cidrsubnet(local.cluster2_cidr, 4, k)]
  cluster2_public_subnets  = [for k, v in [0, 2] : cidrsubnet(local.cluster2_cidr, 8, k + 48)]
}

module "cluster1" {
  providers = {
    aws = aws.region1
  }

  source = "../modules/cluster"

  eks_version         = local.eks_version
  vpc_cidr            = local.cluster1_cidr
  vpc_private_subnets = local.cluster1_private_subnets
  vpc_public_subnets  = local.cluster1_public_subnets

  aws_region = local.cluster1_region

  cluster_name = local.cluster1_name
}

module "cluster2" {
  providers = {
    aws = aws.region2
  }
  source = "../modules/cluster"

  eks_version         = local.eks_version
  vpc_cidr            = local.cluster2_cidr
  vpc_private_subnets = local.cluster2_private_subnets
  vpc_public_subnets  = local.cluster2_public_subnets

  aws_region = local.cluster2_region

  cluster_name = local.cluster2_name
}

provider "aws" {
  region = local.cluster1_region
  alias  = "region1"
}

provider "aws" {
  region = local.cluster2_region
  alias  = "region2"
}

// https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_peering_connection_options#cross-account-usage
// slight difference, same account different region

data "aws_vpc" "first" {
  id       = module.cluster1.vpc_id
  provider = aws.region1
}

data "aws_vpc" "second" {
  id       = module.cluster2.vpc_id
  provider = aws.region2
}

resource "aws_vpc_peering_connection" "this" {
  provider = aws.region1

  vpc_id      = data.aws_vpc.first.id
  peer_vpc_id = data.aws_vpc.second.id
  peer_region = local.cluster2_region
  auto_accept = false // cant
  tags        = { side = "requester", cluster_name = local.cluster1_name }
}

resource "aws_vpc_peering_connection_accepter" "this" {
  provider = aws.region2

  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  auto_accept               = true
  accepter {
    allow_remote_vpc_dns_resolution = true
  }

  tags = {
    side         = "accepter"
    cluster_name = local.cluster2_name
  }
}

resource "aws_vpc_peering_connection_options" "this" {
  provider                  = aws.region1
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }
}
