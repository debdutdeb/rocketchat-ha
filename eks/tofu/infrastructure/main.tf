terraform {
  backend "s3" {
    use_lockfile = true
  }
  required_providers {
    aws = {
      version = ">=6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">=2.0"
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

  sizing = {
    desired = 0
    maximum = 5
    minimum = 0
  }
}

variable "aws_profile" {
  sensitive = true
  type      = string
}

module "cluster1" {
  providers = {
    aws = aws.region1
  }
  sizing = {
    maximum = local.sizing.maximum
    desired = local.sizing.desired
    minimum = local.sizing.minimum
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

  sizing = {
    maximum = local.sizing.maximum
    desired = local.sizing.desired
    minimum = local.sizing.minimum
  }

  eks_version         = local.eks_version
  vpc_cidr            = local.cluster2_cidr
  vpc_private_subnets = local.cluster2_private_subnets
  vpc_public_subnets  = local.cluster2_public_subnets

  aws_region = local.cluster2_region

  cluster_name = local.cluster2_name
}

provider "aws" {
  region  = local.cluster1_region
  alias   = "region1"
  profile = var.aws_profile
  ignore_tags {
    keys = ["CreatedBy"]
  }
}

provider "aws" {
  region  = local.cluster2_region
  alias   = "region2"
  profile = var.aws_profile
  ignore_tags {
    keys = ["CreatedBy"]
  }
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

resource "aws_route" "cluster1_to_cluster2" {
  provider = aws.region1

  count                     = length(module.cluster1.private_route_table_ids)
  route_table_id            = module.cluster1.private_route_table_ids[count.index]
  destination_cidr_block    = local.cluster2_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  depends_on = [aws_vpc_peering_connection_accepter.this]
}

resource "aws_route" "cluster2_to_cluster1" {
  provider = aws.region2

  count                     = length(module.cluster2.private_route_table_ids)
  route_table_id            = module.cluster2.private_route_table_ids[count.index]
  destination_cidr_block    = local.cluster1_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  depends_on = [aws_vpc_peering_connection_accepter.this]
}

resource "local_sensitive_file" "kubeconfig" {
  filename = "${path.cwd}/kube.yaml"
  content = templatefile("${path.cwd}/kube.yaml.tftpl", {
    current_context = module.cluster1.cluster.cluster_name
    clusters = [
      {
        name        = module.cluster1.cluster.cluster_name
        endpoint    = module.cluster1.cluster.cluster_endpoint
        ca_data     = module.cluster1.cluster.cluster_certificate_authority_data
        aws_profile = var.aws_profile
        region      = local.cluster1_region
      },
      {
        name        = module.cluster2.cluster.cluster_name
        endpoint    = module.cluster2.cluster.cluster_endpoint
        ca_data     = module.cluster2.cluster.cluster_certificate_authority_data
        aws_profile = var.aws_profile
        region      = local.cluster2_region
      },
    ]
  })
}

variable "create_coredns" {
  description = "before colium, problem. without cilium, nodes are unhealthy, tofu gets stuck, with no nodes, tofu ok but coredns blocks. turn on later"
  type        = bool
  default     = false
}

resource "aws_eks_addon" "coredns1" {
  provider     = aws.region1
  count        = var.create_coredns ? 1 : 0
  cluster_name = module.cluster1.cluster.cluster_name
  addon_name   = "coredns"

  resolve_conflicts_on_update = "OVERWRITE"

  tags = module.cluster1.common_tags
}

resource "aws_eks_addon" "coredns2" {
  provider     = aws.region2
  count        = var.create_coredns ? 1 : 0
  cluster_name = module.cluster2.cluster.cluster_name
  addon_name   = "coredns"

  resolve_conflicts_on_update = "OVERWRITE"

  tags = module.cluster2.common_tags
}
