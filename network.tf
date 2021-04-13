
data "aws_vpc" "primary" {
  id = module.vpc-primary.vpc_id
}

data "aws_vpc" "secondary" {
  id = module.vpc-secondary.vpc_id
}


data "aws_subnet_ids" "primary" {
  vpc_id = data.aws_vpc.primary.id
}

data "aws_subnet_ids" "secondary" {
  vpc_id = data.aws_vpc.secondary.id
}



resource "aws_vpc_peering_connection" "vpc-peering-primary-secondary" {
  vpc_id      = module.vpc-primary.vpc_id
  peer_vpc_id = module.vpc-secondary.vpc_id
  auto_accept = true

  accepter {
    allow_remote_vpc_dns_resolution = true
  }

  requester {
    allow_remote_vpc_dns_resolution = true
  }
  depends_on = [
    aws_eks_cluster.eks-cluster-primary,
    aws_eks_cluster.eks-cluster-secondary
  ]
}


resource "aws_security_group_rule" "primary2secondary" {
  description              = "Allow nodes from primary VPC to communicate with secondary VPC"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_eks_cluster.eks-cluster-secondary.vpc_config[0].cluster_security_group_id
  security_group_id        = aws_eks_cluster.eks-cluster-primary.vpc_config[0].cluster_security_group_id
  depends_on = [
    aws_eks_cluster.eks-cluster-primary,
    aws_eks_cluster.eks-cluster-secondary,
    aws_eks_node_group.system-cpu-primary,
    aws_eks_node_group.system-cpu-secondary
  ]
}


resource "aws_security_group_rule" "secondary2primary" {
  description              = "Allow nodes from secondary VPC to communicate with secondary VPC"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_eks_cluster.eks-cluster-primary.vpc_config[0].cluster_security_group_id
  security_group_id        = aws_eks_cluster.eks-cluster-secondary.vpc_config[0].cluster_security_group_id
  depends_on = [
    aws_eks_cluster.eks-cluster-primary,
    aws_eks_cluster.eks-cluster-secondary,
    aws_eks_node_group.system-cpu-primary,
    aws_eks_node_group.system-cpu-secondary
  ]
}






resource "aws_route" "primary-public-to-peering" {
  route_table_id            = module.vpc-primary.public_route_table_ids[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.vpc-peering-primary-secondary.id
  destination_cidr_block    = "10.2.0.0/16"
  depends_on                = [aws_vpc_peering_connection.vpc-peering-primary-secondary]
}


resource "aws_route" "primary-private-to-peering" {
  route_table_id            = module.vpc-primary.private_route_table_ids[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.vpc-peering-primary-secondary.id
  destination_cidr_block    = "10.2.0.0/16"
  depends_on                = [aws_vpc_peering_connection.vpc-peering-primary-secondary]
}






resource "aws_route" "secondary-public-to-peering" {
  route_table_id            = module.vpc-secondary.public_route_table_ids[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.vpc-peering-primary-secondary.id
  destination_cidr_block    = "10.1.0.0/16"
  depends_on                = [aws_vpc_peering_connection.vpc-peering-primary-secondary]
}


resource "aws_route" "secondary-private-to-peering" {
  route_table_id            = module.vpc-secondary.private_route_table_ids[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.vpc-peering-primary-secondary.id
  destination_cidr_block    = "10.1.0.0/16"
  depends_on                = [aws_vpc_peering_connection.vpc-peering-primary-secondary]
}

