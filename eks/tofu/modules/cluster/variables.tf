variable "cluster_name" {
  type        = string
  description = "cluster name"
}

variable "vpc_cidr" {
  type        = string
  description = "vpc cidr to use"
}

variable "vpc_public_subnets" {
  type = list(string)
  validation {
    condition     = length(var.vpc_public_subnets) == 2
    error_message = "exactly 2 subnets are required"
  }
}

variable "vpc_private_subnets" {
  type = list(string)
  validation {
    condition     = length(var.vpc_private_subnets) == 2
    error_message = "exactly 2 subnets are required"
  }
}

variable "eks_version" {
  type = string
}

variable "aws_region" {
  type = string
}
