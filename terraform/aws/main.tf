################################################################################
# Variables
################################################################################
variable "region" {
  type        = string
  description = "AWS region"
}
variable "profile" {
  type        = string
  description = "AWS profile"
}

################################################################################
# Data
################################################################################
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  # Exclude local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

################################################################################
# Locals
################################################################################
locals {
  vpc_cidr             = "10.10.0.0/16"
  vpc_node_cidr        = "10.90.0.0/16"
  azs                  = slice(data.aws_availability_zones.available.names, 0, 2)
  name                 = "eks-hybrid"
  cluster_version      = "1.31"
  hybrid_node_name     = "${local.name}-node"
  hybrid_node_pod_cidr = "192.168.0.0/16"
  hybrid_node_ami      = "ami-0df25da1b234a96a8" # ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-20250112
  instance_type        = "t4g.small"
}


################################################################################
# VPC
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "= 5.16.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 101)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 1)]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

module "vpc_node" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "= 5.16.0"

  name = "${local.name}-node"
  cidr = local.vpc_node_cidr

  azs             = local.azs
  private_subnets = [cidrsubnet(local.vpc_node_cidr, 8, 1)]
  public_subnets  = [cidrsubnet(local.vpc_node_cidr, 8, 101)]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_vpc_peering_connection" "this" {
  peer_vpc_id = module.vpc_node.vpc_id
  vpc_id      = module.vpc.vpc_id
  auto_accept = true

  tags = {
    Name = "Peering ${module.vpc.name} - ${module.vpc_node.name}"
  }
}

resource "aws_route" "vpc_public" {
  count = length(module.vpc.public_route_table_ids)

  route_table_id            = module.vpc.public_route_table_ids[count.index]
  destination_cidr_block    = module.vpc_node.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}
resource "aws_route" "vpc_private" {
  count = length(module.vpc_node.private_route_table_ids)

  route_table_id            = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block    = module.vpc_node.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}
resource "aws_route" "vpc_node_private" {
  count = length(module.vpc_node.private_route_table_ids)

  route_table_id            = module.vpc_node.private_route_table_ids[count.index]
  destination_cidr_block    = module.vpc.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}


################################################################################
# EKS
################################################################################
module "eks_hybrid_node_role" {
  source  = "terraform-aws-modules/eks/aws//modules/hybrid-node-role"
  version = "~> 20.31"
}

resource "aws_iam_role" "eks_managed_node_group" {
  name = "${local.hybrid_node_name}-managed-node-group-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "eks_managed_node_group_ssm" {
  role       = aws_iam_role.eks_managed_node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy_attachment" "eks_managed_node_group_ecr" {
  role       = aws_iam_role.eks_managed_node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
resource "aws_iam_role_policy_attachment" "eks_managed_node_group_workernode" {
  role       = aws_iam_role.eks_managed_node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}
resource "aws_iam_role_policy_attachment" "eks_managed_node_group_cni" {
  role       = aws_iam_role.eks_managed_node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
resource "aws_security_group" "eks_managed_node_group" {
  name   = "${local.name}-managed-node-group"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.vpc.vpc_cidr_block, module.vpc_node.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.33.1"

  cluster_name    = local.name
  cluster_version = local.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  cluster_security_group_additional_rules = {
    hybrid-all = {
      cidr_blocks = [module.vpc_node.vpc_cidr_block]
      description = "Allow all traffic from remote node/pod network"
      from_port   = 0
      to_port     = 0
      protocol    = "all"
      type        = "ingress"
    }
  }

  access_entries = {
    hybrid-node-role = {
      principal_arn = module.eks_hybrid_node_role.arn
      type          = "HYBRID_LINUX"
    }
  }


  eks_managed_node_groups = {
    "${local.name}-managed-node" = {
      ami_type              = "AL2_ARM_64"
      instance_types        = [local.instance_type]
      min_size              = 1
      max_size              = 2
      desired_size          = 1
      capacity_type         = "SPOT"
      create_iam_role       = false
      iam_role_arn          = aws_iam_role.eks_managed_node_group.arn
      create_security_group = false
      vpc_security_group_ids = [
        aws_security_group.eks_managed_node_group.id
      ]
    }
  }


  cluster_remote_network_config = {
    remote_node_networks = {
      cidrs = [module.vpc_node.vpc_cidr_block]
    }
    remote_pod_networks = {
      cidrs = [local.hybrid_node_pod_cidr]
    }
  }
}


# Hybrid Nodes アクティベーション用
resource "aws_ssm_activation" "this" {
  description        = "EKS Hybrid Nodes Activation"
  iam_role           = module.eks_hybrid_node_role.name
  registration_limit = 10
  tags = {
    EKSClusterARN = "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${module.eks.cluster_name}"
  }
}


################################################################################
# Hybrid Node
################################################################################

resource "aws_security_group" "node" {
  name   = "${local.name}-node"
  vpc_id = module.vpc_node.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_iam_role" "node" {
  name = "${local.hybrid_node_name}-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "node" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name = "${local.hybrid_node_name}-role-profile"
  role = aws_iam_role.node.name
}

resource "aws_instance" "node" {
  ami                         = local.hybrid_node_ami
  instance_type               = local.instance_type
  subnet_id                   = module.vpc_node.private_subnets[0]
  associate_public_ip_address = false
  user_data_replace_on_change = true

  iam_instance_profile   = aws_iam_instance_profile.node.name
  vpc_security_group_ids = [aws_security_group.node.id]


  root_block_device {
    encrypted = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }


  capacity_reservation_specification {
    capacity_reservation_preference = "none"
  }
  tags = {
    Name = "${local.name}-node"
  }
  user_data = <<EOF
Content-Type: multipart/mixed; boundary="==BOUNDARY=="
MIME-Version:  1.0

--==BOUNDARY==
Content-Type: text/cloud-config; charset="us-ascii"
MIME-Version:  1.0
#cloud-config
runcmd:
  - [hostnamectl,set-hostname,${local.name}-node]

--==BOUNDARY==
Content-Type: text/cloud-config; charset="us-ascii"
MIME-Version:  1.0
#cloud-config
package_update: true
packages:
  - nc

--==BOUNDARY==
Content-Type: text/cloud-config; charset="us-ascii"
MIME-Version: 1.0
#cloud-config

write_files:
  - path: /etc/nodeadm/nodeConfig.yaml
    owner: root:root
    permissions: '0644'
    content: |
      apiVersion: node.eks.aws/v1alpha1
      kind: NodeConfig
      spec:
        cluster:
          name: eks-hybrid
          region: ap-northeast-1
        hybrid:
          ssm:
            activationCode: ${aws_ssm_activation.this.activation_code}
            activationId:   ${aws_ssm_activation.this.id}

runcmd:
  - curl -OL 'https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/arm64/nodeadm'
  - mv nodeadm /usr/bin/nodeadm
  - chmod +x /usr/bin/nodeadm
  - nodeadm install ${local.cluster_version} --credential-provider ssm
  - nodeadm init -c file:///etc/nodeadm/nodeConfig.yaml
  - nodeadm debug -c file:///etc/nodeadm/nodeConfig.yaml

--==BOUNDARY==--
EOF

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# ALB
################################################################################

# ALB用セキュリティグループ
resource "aws_security_group" "alb" {
  name   = "${local.name}-alb"
  vpc_id = module.vpc.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_lb" "this" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets
}

resource "aws_lb_target_group" "this" {
  name        = "${local.name}-alb"
  vpc_id      = module.vpc.vpc_id
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}
