terraform {
  required_providers {
    aws = {
      version = ">=6.0"
    }
    utils = {
      source = "registry.terraform.io/halter/utils"
    }
  }
}

data "aws_region" "this" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    tier          = "staging"
    owner_cluster = var.cluster_name
    vpc_cidr      = var.vpc_cidr
    eks_version   = var.eks_version
  }

  disabled_cidr = "172.17.0.0/16"
}

// vpc creation is manual; as inspired by https://docs.cilium.io/en/stable/network/clustermesh/eks-clustermesh-prep/

//Cluster_1_VPC=$(aws ec2 create-vpc \
//    --cidr-block 10.0.0.0/16 \
//    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=Cluster_1_VPC}]" \
//    --region ${AWS_REGION} \
//    --query 'Vpc.{VpcId:VpcId}' \
//    --output text
//)
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr
  tags       = merge(local.tags, { Name = "${var.cluster_name}-vpc" })

  enable_dns_hostnames = true
  enable_dns_support   = true

  lifecycle {
    precondition {
      condition = (
        !provider::utils::cidroverlaps(var.vpc_cidr, local.disabled_cidr) &&
        provider::utils::cidrnoverlap(concat(var.vpc_public_subnets, var.vpc_private_subnets))
      )
      error_message = "\"${local.disabled_cidr}\" range is blocked, read https://docs.cilium.io/en/stable/network/clustermesh/eks-clustermesh-prep/"
    }
  }
}

// export Cluster_1_Public_Subnet_1=$(aws ec2 create-subnet \
//     --vpc-id ${Cluster_1_VPC} \
//     --cidr-block 10.0.1.0/24 \
//     --availability-zone ${AWS_REGION}a \
//     --tag-specifications "ResourceType=subnet, Tags=[{Key=Name,Value=Cluster_1_Public_Subnet_1},{Key=kubernetes.io/role/elb,Value=1}]" \
//     --query 'Subnet.{SubnetId:SubnetId}' \
//     --output text
// )
// 
// export Cluster_1_Public_Subnet_2=$(aws ec2 create-subnet \
//     --vpc-id ${Cluster_1_VPC} \
//     --cidr-block 10.0.2.0/24 \
//     --availability-zone ${AWS_REGION}b \
//     --tag-specifications "ResourceType=subnet, Tags=[{Key=Name,Value=Cluster_1_Public_Subnet_2},{Key=kubernetes.io/role/elb,Value=1}]" \
//     --query 'Subnet.{SubnetId:SubnetId}' \
//     --output text
// )
resource "aws_subnet" "public" {
  count                           = 2
  vpc_id                          = aws_vpc.this.id
  region                          = data.aws_region.this.name
  assign_ipv6_address_on_creation = false // no ip6 let's force it
  cidr_block                      = var.vpc_public_subnets[count.index]
  availability_zone               = local.azs[count.index]
  tags = merge(local.tags, {
    Name                     = "${var.cluster_name}-public-${count.index + 1}"
    "kubernetes.io/role/elb" = "1"
  })
}

// export Cluster_1_Private_Subnet_1=$(aws ec2 create-subnet ... --tag-specifications "...{Key=kubernetes.io/role/internal-elb,Value=1}]")
resource "aws_subnet" "private" {
  count                           = 2
  vpc_id                          = aws_vpc.this.id
  region                          = data.aws_region.this.name
  assign_ipv6_address_on_creation = false // no ip6 let's force it
  cidr_block                      = var.vpc_private_subnets[count.index]
  availability_zone               = local.azs[count.index]
  tags = merge(local.tags, {
    Name                              = "${var.cluster_name}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.cluster_name}-igw" })
}

resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.cluster_name}-nat-eip-${count.index + 1}" })
}

resource "aws_nat_gateway" "this" {
  count         = 2
  subnet_id     = aws_subnet.public[count.index].id
  allocation_id = aws_eip.nat[count.index].id
  tags          = merge(local.tags, { Name = "${var.cluster_name}-natgw-${count.index + 1}" })
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.cluster_name}-public-rt" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

// one private route table per AZ, each defaulting through that AZ's own NAT gateway
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.cluster_name}-private-rt-${count.index + 1}" })
}

resource "aws_route" "private_nat" {
  count                  = 2
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_security_group" "this" {
  name        = "${var.cluster_name}-clustermesh"
  description = "Security group for ${var.cluster_name}"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.cluster_name}-clustermesh" })
}

resource "aws_security_group_rule" "self_ingress" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.this.id
  source_security_group_id = aws_security_group.this.id
}

resource "aws_security_group_rule" "egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.this.id
  cidr_blocks       = ["0.0.0.0/0"]
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                   = var.cluster_name
  kubernetes_version     = var.eks_version
  endpoint_public_access = true

  // TODO: disabling this means what? does it also disable iam access? aws-auth cm looks like what? documented?
  enable_cluster_creator_admin_permissions = true

  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.private[*].id

  eks_managed_node_groups = {
    initial = {
      instance_types = ["t4g.medium"]

      ami_type = "AL2023_ARM_64_STANDARD"

      min_size     = var.sizing.minimum
      max_size     = var.sizing.maximum
      desired_size = var.sizing.desired

      taints = {
        agent-not-ready = {
          key    = "node.cilium.io/agent-not-ready"
          value  = "true"
          effect = "NO_EXECUTE"
        }
      }
    }
  }


  // handle addons in caller
  addons = {}
  # addons = {
  #   // add this separately
  #   coredns    = {
  #     timeout = "1m00s" // this will fail
  #   }
  #   kube-proxy = {}
  #   vpc-cni = {
  #     before_compute = true
  #   }
  # }
  tags = local.tags
}
