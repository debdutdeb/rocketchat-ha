output "vpc_id" {
	value = aws_vpc.this.id
}

output "cluster" {
  value = module.eks
}
