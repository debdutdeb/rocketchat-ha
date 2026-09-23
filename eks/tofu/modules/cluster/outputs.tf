output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_route_table_ids" {
  value = aws_route_table.private[*].id
}

output "cluster" {
  value = module.eks
}

output "common_tags" {
  value = local.tags
}
