module "vpc-primary" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "2.68.0"

  name                 = "vpc-primary"
  cidr                 = "10.1.0.0/16"
  azs                  = ["us-east-1a", "us-east-1b"]
  private_subnets      = ["10.1.0.0/18", "10.1.64.0/18"]
  public_subnets       = ["10.1.128.0/18", "10.1.192.0/18"]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/eks-cluster-primary" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/eks-cluster-primary" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}


resource "aws_eks_cluster" "eks-cluster-primary" {
  name     = "eks-cluster-primary"
  role_arn = aws_cloudformation_stack.eks_iam_infra.outputs["eksClusterRoleARN"]
  version  = "1.19"
  vpc_config {
    subnet_ids = [module.vpc-primary.private_subnets[0], module.vpc-primary.private_subnets[1], module.vpc-primary.public_subnets[0], module.vpc-primary.public_subnets[1]]
  }

  kubernetes_network_config {
    service_ipv4_cidr = "172.20.0.0/14"
  }

  depends_on = [
    module.vpc-primary,
    aws_cloudformation_stack.eks_iam_infra,
  ]
}

resource "aws_eks_node_group" "system-cpu-primary" {
  cluster_name    = aws_eks_cluster.eks-cluster-primary.name
  node_group_name = "system-cpu"
  node_role_arn   = aws_cloudformation_stack.eks_iam_infra.outputs["eksNodeRoleARN"]
  subnet_ids      = [module.vpc-primary.private_subnets[0], module.vpc-primary.private_subnets[1]]

  ami_type       = "AL2_x86_64"
  capacity_type  = "ON_DEMAND"
  instance_types = ["m5.large"]

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 1
  }

  tags = {
    "k8s.io/cluster-autoscaler/enabled"             = "TRUE",
    "k8s.io/cluster-autoscaler/eks-cluster-primary" = "owned"
  }
  depends_on = [aws_eks_cluster.eks-cluster-primary]
}

resource "aws_eks_node_group" "gpu-primary" {
  cluster_name    = aws_eks_cluster.eks-cluster-primary.name
  node_group_name = "gpu"
  node_role_arn   = aws_cloudformation_stack.eks_iam_infra.outputs["eksNodeRoleARN"]
  subnet_ids      = [module.vpc-primary.private_subnets[0], module.vpc-primary.private_subnets[1]]

  ami_type       = "AL2_x86_64_GPU"
  capacity_type  = "ON_DEMAND"
  instance_types = ["g4dn.xlarge"]

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 1
  }

  tags = {
    "k8s.io/cluster-autoscaler/enabled"             = "TRUE",
    "k8s.io/cluster-autoscaler/eks-cluster-primary" = "owned"
  }
  depends_on = [aws_eks_cluster.eks-cluster-primary]
}

resource "aws_eks_node_group" "cpu-spot-primary" {
  cluster_name    = aws_eks_cluster.eks-cluster-primary.name
  node_group_name = "cpu-spot"
  node_role_arn   = aws_cloudformation_stack.eks_iam_infra.outputs["eksNodeRoleARN"]
  subnet_ids      = [module.vpc-primary.private_subnets[0], module.vpc-primary.private_subnets[1]]

  ami_type       = "AL2_x86_64"
  capacity_type  = "SPOT"
  instance_types = ["m5.large"]

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 1
  }
  tags = {
    "k8s.io/cluster-autoscaler/enabled"             = "TRUE",
    "k8s.io/cluster-autoscaler/eks-cluster-primary" = "owned"
  }
  depends_on = [aws_eks_cluster.eks-cluster-primary]
}


resource "aws_eks_node_group" "gpu-spot-primary" {
  cluster_name    = aws_eks_cluster.eks-cluster-primary.name
  node_group_name = "gpu-spot"
  node_role_arn   = aws_cloudformation_stack.eks_iam_infra.outputs["eksNodeRoleARN"]
  subnet_ids      = [module.vpc-primary.private_subnets[0], module.vpc-primary.private_subnets[1]]

  ami_type       = "AL2_x86_64_GPU"
  capacity_type  = "SPOT"
  instance_types = ["p3.2xlarge"]

  scaling_config {
    desired_size = 1
    max_size     = 4
    min_size     = 1
  }
  tags = {
    "k8s.io/cluster-autoscaler/enabled"             = "TRUE",
    "k8s.io/cluster-autoscaler/eks-cluster-primary" = "owned"
  }
  depends_on = [aws_eks_cluster.eks-cluster-primary]
}


data "aws_eks_cluster" "eks-cluster-primary-source" {
  name = aws_eks_cluster.eks-cluster-primary.id
}

data "aws_eks_cluster_auth" "eks-cluster-primary-auth" {
  name = aws_eks_cluster.eks-cluster-primary.id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.eks-cluster-primary-source.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks-cluster-primary-source.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.eks-cluster-primary-auth.token
  alias                  = "primary"
}

# k8s manifests

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.eks-cluster-primary-source.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks-cluster-primary-source.certificate_authority.0.data)
    token                  = data.aws_eks_cluster_auth.eks-cluster-primary-auth.token
  }
  alias = "primary"
}




resource "null_resource" "delete_aws_node_primary" {

  provisioner "local-exec" {
    command = "aws eks --region us-east-1 update-kubeconfig --name eks-cluster-primary && kubectl config set-context arn:aws:eks:us-east-1:667183617042:cluster/eks-cluster-primary && kubectl -n kube-system delete daemonset aws-node && sleep 30"
  }
  depends_on = [aws_eks_node_group.system-cpu-primary, aws_eks_node_group.gpu-primary]
}

# helm releases


resource "helm_release" "cilium_primary" {
  provider = helm.primary

  depends_on = [aws_eks_node_group.system-cpu-primary, aws_eks_node_group.gpu-primary, null_resource.delete_aws_node_primary]
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

resource "helm_release" "aws-node-termination-handler_primary" {
  provider   = helm.primary
  depends_on = [helm_release.cilium_primary]
  name       = "aws-node-termination-handler"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-node-termination-handler"
}

  
resource "helm_release" "cluster-autoscaler-primary" {
  provider   = helm.primary
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
    value = "eks-cluster-primary"
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



resource "helm_release" "nvidia_device_plugin_primary" {
  provider   = helm.primary
  depends_on = [aws_eks_node_group.gpu-primary, helm_release.cilium_primary]
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


resource "helm_release" "gpu_feature_discovery_primary" {
  provider   = helm.primary
  depends_on = [helm_release.nvidia_device_plugin_primary]
  name       = "gpu-feature-discovery"
  version    = "0.3.0"
  namespace  = "kube-system"
  #chart      = "https://nvidia.github.com/gpu-feature-discovery/stable/gpu-feature-discovery-0.4.1.tgz"
  repository = "https://nvidia.github.io/gpu-feature-discovery"
  chart = "gpu-feature-discovery"
}




