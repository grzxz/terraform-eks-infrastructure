
locals {
  mapped_role_format = <<MAPPEDROLE
- rolearn: %s
  username: system:node:{{EC2PrivateDNSName}}
  groups:
    - system:bootstrappers
    - system:nodes
MAPPEDROLE

}



resource "aws_cloudformation_stack" "eks_iam_infra" {
  name          = "eks-iam-infra"
  capabilities  = ["CAPABILITY_IAM"]
  template_body = <<STACK
{
  "Resources" : {
    "eksClusterRole": {
            "Type": "AWS::IAM::Role",
            "Properties": {
                "AssumeRolePolicyDocument": {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Principal": {
                                "Service": [
                                    "eks.amazonaws.com"
                                ]
                            },
                            "Action": [
                                "sts:AssumeRole"
                            ]
                        }
                    ]
                },
                "ManagedPolicyArns": [
                    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
                ]
            }
        },
    "eksNodeInstanceProfile": {
            "Type": "AWS::IAM::InstanceProfile",
            "Properties": {
                "Path": "/",
                "Roles": [
                    {
                        "Ref": "eksNodeRole"
                    }
                ]
            }
        },
    "eksNodeRole": {
            "Type": "AWS::IAM::Role",
            "Properties": {
                "AssumeRolePolicyDocument": {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Principal": {
                                "Service": [
                                    "ec2.amazonaws.com"
                                ]
                            },
                            "Action": [
                                "sts:AssumeRole"
                            ]
                        }
                    ]
                },
                "Path": "/",
                "ManagedPolicyArns": [
                    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
                    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
                    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
                ],
                "Policies": [
                    {
                        "PolicyName": "ClusterAutoscaler",
                        "PolicyDocument": {
                            "Version": "2012-10-17",
                            "Statement": [
                                {
                                    "Sid": "K8NodeASGPerms",
                                    "Effect": "Allow",
                                    "Action": [
                                        "autoscaling:DescribeAutoScalingGroups",
                                        "autoscaling:DescribeAutoScalingInstances",
                                        "autoscaling:DescribeLaunchConfigurations",
                                        "autoscaling:SetDesiredCapacity",
                                        "autoscaling:DescribeTags",
                                        "autoscaling:TerminateInstanceInAutoScalingGroup",
                                        "autoscaling:DescribeTags"
                                    ],
                                    "Resource": "*"
                                }
                            ]
                        }
                    }
                ]
            }
    }
    
  },
  
  "Outputs": {
    "eksClusterRoleARN": {
      "Value": { "Fn::GetAtt" : [ "eksClusterRole", "Arn" ] }
    },
    "eksNodeRoleARN": {
      "Value": { "Fn::GetAtt" : [ "eksNodeRole", "Arn" ] }
    },
    "eksNodeRoleName": {
      "Value": { "Fn::GetAtt" : [ "eksNodeRole", "RoleId" ] }
    }
}
}
STACK
}

module "iam_assumable_role_admin" {
  source                        = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version                       = "3.6.0"
  create_role                   = true
  role_name                     = "cluster-autoscaler"
  provider_url                  = replace(aws_eks_cluster.eks-cluster-primary.identity["0"].oidc.0.issuer, "https://", "")
  role_policy_arns              = [aws_iam_policy.cluster_autoscaler.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:system:serviceaccount:kube-system:cluster-autoscaler"]
  depends_on = [
    aws_iam_policy.cluster_autoscaler,
    aws_cloudformation_stack.eks_iam_infra,
    aws_eks_cluster.eks-cluster-primary
  ]
}


resource "aws_iam_policy" "cluster_autoscaler" {
  name_prefix = "cluster-autoscaler"
  description = "EKS cluster-autoscaler policy for cluster eks-cluster-primary"
  policy      = data.aws_iam_policy_document.cluster_autoscaler.json
}

data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    sid    = "clusterAutoscalerAll"
    effect = "Allow"

    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
      "ec2:DescribeLaunchTemplateVersions",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "clusterAutoscalerOwn"
    effect = "Allow"

    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/kubernetes.io/cluster/eks-cluster-primary"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"
      values   = ["true"]
    }
  }
}