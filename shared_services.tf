module "vpc-shared-services" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "2.68.0"

  name                 = "vpc-shared-services"
  cidr                 = "10.0.0.0/16"
  azs                  = ["us-east-1a", "us-east-1b"]
  private_subnets      = ["10.0.0.0/18", "10.0.64.0/18"]
  public_subnets       = ["10.0.128.0/18", "10.0.192.0/18"]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/eks-cluster-shared-services" = "shared"
    "kubernetes.io/role/elb"                            = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/eks-cluster-shared-services" = "shared"
    "kubernetes.io/role/internal-elb"                   = "1"
  }
}

resource "aws_eks_cluster" "eks-cluster-shared-services" {
  name     = "eks-cluster-shared-services"
  role_arn = aws_cloudformation_stack.eks_iam_infra.outputs["eksClusterRoleARN"]
  version  = "1.19"
  vpc_config {
    subnet_ids = [module.vpc-shared-services.private_subnets[0], module.vpc-shared-services.private_subnets[1], module.vpc-shared-services.public_subnets[0], module.vpc-shared-services.public_subnets[1]]
  }

  kubernetes_network_config {
    service_ipv4_cidr = "172.16.0.0/14"
  }

  depends_on = [
    module.vpc-shared-services,
    aws_cloudformation_stack.eks_iam_infra,
  ]
}

resource "aws_eks_node_group" "system-cpu-shared-services" {
  cluster_name    = aws_eks_cluster.eks-cluster-shared-services.name
  node_group_name = "system-cpu"
  node_role_arn   = aws_cloudformation_stack.eks_iam_infra.outputs["eksNodeRoleARN"]
  subnet_ids      = [module.vpc-shared-services.private_subnets[0], module.vpc-shared-services.private_subnets[1]]

  ami_type       = "AL2_x86_64"
  capacity_type  = "ON_DEMAND"
  instance_types = ["m5.large"]

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 1
  }

  depends_on = [aws_eks_cluster.eks-cluster-shared-services]
}

/*
resource "aws_eks_node_group" "gpu-shared-services" {
  cluster_name    = aws_eks_cluster.eks-cluster-shared-services.name
  node_group_name = "gpu"
  node_role_arn   = aws_cloudformation_stack.eks_iam_infra.outputs["eksNodeRoleARN"]
  subnet_ids      = [module.vpc-shared-services.private_subnets[0], module.vpc-shared-services.private_subnets[1]]

  ami_type       = "AL2_x86_64"
  capacity_type  = "ON_DEMAND"
  instance_types = ["g4dn.xlarge"]

  scaling_config {
    desired_size = 1
    max_size     = 4
    min_size     = 1
  }

  depends_on = [aws_eks_cluster.eks-cluster-shared-services]
}
*/

data "aws_eks_cluster" "eks-cluster-shared-services-source" {
  name = aws_eks_cluster.eks-cluster-shared-services.id
}

data "aws_eks_cluster_auth" "eks-cluster-shared-services-auth" {
  name = aws_eks_cluster.eks-cluster-shared-services.id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.eks-cluster-shared-services-source.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks-cluster-shared-services-source.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.eks-cluster-shared-services-auth.token
  alias                  = "shared-services"
}

# k8s manifests


provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.eks-cluster-shared-services-source.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks-cluster-shared-services-source.certificate_authority.0.data)
    token                  = data.aws_eks_cluster_auth.eks-cluster-shared-services-auth.token
  }
  alias = "shared-services"
}


resource "null_resource" "delete_aws_node_shared_services" {

  provisioner "local-exec" {
    command = "aws eks --region us-east-1 update-kubeconfig --name eks-cluster-shared-services && kubectl config set-context arn:aws:eks:us-east-1:667183617042:cluster/eks-cluster-shared-services && kubectl -n kube-system delete daemonset aws-node && sleep 30"
  }
  depends_on = [aws_eks_node_group.system-cpu-shared-services, null_resource.delete_aws_node_secondary]
}

resource "helm_release" "cilium_shared_services" {
  provider   = helm.shared-services
  depends_on = [aws_eks_node_group.system-cpu-shared-services, null_resource.delete_aws_node_shared_services]
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

resource "helm_release" "aws-node-termination-handler-shared-services" {
  provider   = helm.shared-services
  depends_on = [helm_release.cilium_shared_services]
  name       = "aws-node-termination-handler"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-node-termination-handler"
}


/*

resource "helm_release" "nvidia_device_plugin_shared_services" {
  provider = helm.shared-services
  depends_on = [aws_eks_node_group.gpu-shared-services, helm_release.cilium_shared_services]
  name       = "nvidia-device-plugin"
  version    = "0.7.0"
  namespace = "kube-system"

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

resource "helm_release" "gpu_feature_discovery_shared_services" {
  provider = helm.shared-services
  depends_on = [helm_release.nvidia_device_plugin_shared_services]
  name       = "gpu-feature-discovery"
  version    = "0.3.0"
  namespace = "kube-system"
  repository = "https://nvidia.github.io/gpu-feature-discovery"
  chart = "gpu-feature-discovery"
}


*/