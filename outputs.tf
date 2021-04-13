
output "public_route_tables_primary" {
  value = module.vpc-primary.public_route_table_ids
}

output "private_route_tables_primary" {
  value = module.vpc-primary.private_route_table_ids
}


output "public_route_tables_secondary" {
  value = module.vpc-secondary.public_route_table_ids
}

output "private_route_tables_secondary" {
  value = module.vpc-secondary.private_route_table_ids
}



output "eks-cluster-primary_cluster_security_group_id" {
  value = aws_eks_cluster.eks-cluster-primary.vpc_config[0].cluster_security_group_id
}

output "eks-cluster-secondary_cluster_security_group_id" {
  value = aws_eks_cluster.eks-cluster-secondary.vpc_config[0].cluster_security_group_id
}
