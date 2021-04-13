module "vpc-secondary" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "2.68.0"

  name                 = "vpc-secondary"
  cidr                 = "10.2.0.0/16"
  azs                  = ["us-east-1a", "us-east-1b"]
  private_subnets      = ["10.2.0.0/18", "10.2.64.0/18"]
  public_subnets       = ["10.2.128.0/18", "10.2.192.0/18"]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/eks-cluster-secondary" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/eks-cluster-secondary" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}


resource "aws_eks_cluster" "eks-cluster-secondary" {
  name     = "eks-cluster-secondary"
  role_arn = aws_cloudformation_stack.eks_iam_infra.outputs["eksClusterRoleARN"]
  version  = "1.19"
  vpc_config {
    subnet_ids = [module.vpc-secondary.private_subnets[0], module.vpc-secondary.private_subnets[1], module.vpc-secondary.public_subnets[0], module.vpc-secondary.public_subnets[1]]
  }

  kubernetes_network_config {
    service_ipv4_cidr = "172.24.0.0/14"
  }

  depends_on = [
    module.vpc-secondary,
    aws_cloudformation_stack.eks_iam_infra,
  ]
}

resource "aws_eks_node_group" "system-cpu-secondary" {
  cluster_name    = aws_eks_cluster.eks-cluster-secondary.name
  node_group_name = "system-cpu"
  node_role_arn   = aws_cloudformation_stack.eks_iam_infra.outputs["eksNodeRoleARN"]
  subnet_ids      = [module.vpc-secondary.private_subnets[0], module.vpc-secondary.private_subnets[1]]

  ami_type       = "AL2_x86_64"
  capacity_type  = "ON_DEMAND"
  instance_types = ["m5.large"]

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 1
  }

  depends_on = [aws_eks_cluster.eks-cluster-secondary]
}


resource "aws_eks_node_group" "gpu-secondary" {
  cluster_name    = aws_eks_cluster.eks-cluster-secondary.name
  node_group_name = "gpu"
  node_role_arn   = aws_cloudformation_stack.eks_iam_infra.outputs["eksNodeRoleARN"]
  subnet_ids      = [module.vpc-secondary.private_subnets[0], module.vpc-secondary.private_subnets[1]]

  ami_type       = "AL2_x86_64_GPU"
  capacity_type  = "ON_DEMAND"
  instance_types = ["g4dn.xlarge"]

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 1
  }

  depends_on = [aws_eks_cluster.eks-cluster-secondary]
}

/*
resource "aws_eks_node_group" "gpu-spot-secondary" {
  cluster_name    = aws_eks_cluster.eks-cluster-secondary.name
  node_group_name = "gpu-spot"
  node_role_arn   = aws_cloudformation_stack.eks_iam_infra.outputs["eksNodeRoleARN"]
  subnet_ids      = [module.vpc-secondary.private_subnets[0], module.vpc-secondary.private_subnets[1]]

  ami_type       = "AL2_x86_64_GPU"
  capacity_type  = "SPOT"
  instance_types = ["g4dn.xlarge"]

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 1
  }

  depends_on = [aws_eks_cluster.eks-cluster-secondary]
}
*/



data "aws_eks_cluster" "eks-cluster-secondary-source" {
  name = aws_eks_cluster.eks-cluster-secondary.id
}

data "aws_eks_cluster_auth" "eks-cluster-secondary-auth" {
  name = aws_eks_cluster.eks-cluster-secondary.id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.eks-cluster-secondary-source.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks-cluster-secondary-source.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.eks-cluster-secondary-auth.token
  alias                  = "secondary"
}


# k8s manifests

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.eks-cluster-secondary-source.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks-cluster-secondary-source.certificate_authority.0.data)
    token                  = data.aws_eks_cluster_auth.eks-cluster-secondary-auth.token
  }
  alias = "secondary"
}

resource "null_resource" "delete_aws_node_secondary" {

  provisioner "local-exec" {
    command = "aws eks --region us-east-1 update-kubeconfig --name eks-cluster-secondary && kubectl config set-context arn:aws:eks:us-east-1:667183617042:cluster/eks-cluster-secondary && kubectl -n kube-system delete daemonset aws-node && sleep 30"
  }
  depends_on = [aws_eks_node_group.system-cpu-secondary, aws_eks_node_group.gpu-secondary, null_resource.delete_aws_node_primary]
}


resource "helm_release" "cilium_secondary" {
  provider   = helm.secondary
  depends_on = [aws_eks_node_group.system-cpu-secondary, aws_eks_node_group.gpu-secondary, null_resource.delete_aws_node_secondary]
  name       = "cilium"
  version    = "1.9.3"
  namespace  = "kube-system"

  chart = "https://raw.githack.com/cilium/charts/master/cilium-1.9.3.tgz"

  set {
    name  = "eni"
    value = "true"
  }
  set {
    name  = "ipam.mode"
    value = "eni"
  }
  set {
    name  = "egressMasqueradeInterfaces"
    value = "eth0"
  }
  set {
    name  = "tunnel"
    value = "disabled"
  }
  set {
    name  = "nodeinit.enabled"
    value = "true"
  }
  set {
    name  = "etcd.enabled"
    value = "true"
  }
  set {
    name  = "etcd.managed"
    value = "true"
  }
  set {
    name  = "identityAllocationMode"
    value = "kvstore"
  }
  set {
    name  = "etcd.k8sService"
    value = "true"
  }
  set {
    name  = "hubble.listenAddress"
    value = ":4244"
  }
  set {
    name  = "hubble.relay.enabled"
    value = "true"
  }
  set {
    name  = "hubble.ui.enabled"
    value = "true"
  }
}

resource "helm_release" "aws-node-termination-handler-secondary" {
  provider   = helm.secondary
  depends_on = [helm_release.cilium_secondary]
  name       = "aws-node-termination-handler"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-node-termination-handler"
}

  
resource "helm_release" "cluster-autoscaler-secondary" {
  provider   = helm.secondary
  depends_on = [helm_release.cilium_primary]
  name       = "cluster-autoscaler"
  namespace  = "kube-system"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  set {
    name  = "rbac.create"
    value = "true"
  }
  set {
    name  = "cloudProvider"
    value = "aws"
  }
  set {
    name  = "awsRegion"
    value = "us-east-1"
  }
  set {
    name  = "autoDiscovery.clusterName"
    value = "eks-cluster-secondary"
  }
  set {
    name  = "autoDiscovery.enabled"
    value = "true"
  }
  set {
    name  = "image.repository"
    value = "us.gcr.io/k8s-artifacts-prod/autoscaling/cluster-autoscaler"
  }
  set {
    name  = "image.tag"
    value = "v1.19.0"
  }
}


resource "helm_release" "nvidia_device_plugin_secondary" {
  provider   = helm.secondary
  depends_on = [aws_eks_node_group.gpu-secondary, helm_release.cilium_secondary]
  name       = "nvidia-device-plugin"
  version    = "0.9.0"
  namespace  = "kube-system"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart = "nvidia-device-plugin"
  

  set {
    name  = "resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resources.limits.memory"
    value = "512Mi"
  }
  set {
    name  = "failOnInitError"
    value = "false"
  }
}



resource "helm_release" "gpu_feature_discovery_secondary" {
  provider   = helm.secondary
  depends_on = [helm_release.nvidia_device_plugin_secondary]
  name       = "gpu-feature-discovery"
  version    = "0.4.1"
  namespace  = "kube-system"
  repository = "https://nvidia.github.io/gpu-feature-discovery"
  chart = "gpu-feature-discovery"
}

