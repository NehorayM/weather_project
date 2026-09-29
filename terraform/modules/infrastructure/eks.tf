
/*
eks the module creates to me the iam cluster role of the cluster and the node 
and i configing the security group of the node 
and the cluster and the node group
and the launch template of the node group 
and the oidc provider for the cluster
*/
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"
  # the name of the claster 
  cluster_name    = "${var.project}-eks"
  cluster_version = var.cluster_version

  # allow to diny accses or let trafice hit the api server from endpoint 
  cluster_endpoint_public_access = var.enable_public_endpoint
  #creat enpoint so the worker node or the jenkins contruller will have direct accesse to the api server 
  cluster_endpoint_private_access = true

  #the id of the vpc wich greant as tbe place the eni of the controle plane and the worker nodes will 
  vpc_id = var.vpc_id
  # the subnet ids of the eks contrull plane will put the eni of his across the subents 
  subnet_ids = var.private_subnet_ids

  # creat an iam policy to the cluster AmazonEKSClusterAdminPolicy wich greant to talk with the api for the terrafrume
  enable_cluster_creator_admin_permissions = true
  #addons for the claster 

  cluster_addons = {
    # creat a dns internaly for the claster for names of pods and services
    coredns = {}
    # mange the iptavles of the nodes 
    kube-proxy = {}
    # use deamon set that let an iam role for identy to the pods 
    eks-pod-identity-agent = {}
    # creat cni for the nodes
    vpc-cni = {
      before_compute = true
    }
    aws-ebs-csi-driver = { configuration_values = jsonencode({
      controller = {
        replicaCount = 1
      }
    }) }
  }

  eks_managed_node_groups = {
    #the block of aws manged node groups 
    default = {
      name           = "${var.project}-ng"
      instance_types = ["m7i-flex.large"]
      # amzon linux
      ami_type = "AL2023_x86_64_STANDARD"
      #for rolling update 
      min_size     = 1
      max_size     = 2
      desired_size = 1
      # i am puting the node sits beside the jenkins controller so the jnlp channel will not leave the vpc and will not be blocked by the alb
      subnet_ids = [var.private_subnet_ids[1]]


      #the module builds a castome launch template for the node group and i am adding a block device mapping to it so the root volume will be 75 gb and encrypted

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 75
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }

      }

    }
  }

  node_security_group_additional_rules = {
    alb_to_pods = {
      description              = "ALB to pod container ports"
      protocol                 = "tcp"
      from_port                = 3000
      to_port                  = 8080
      type                     = "ingress"
      source_security_group_id = var.alb_sg_id
    }
  }

  #  creat a role for the 
  cluster_security_group_additional_rules = {
    jenkins_to_api = {
      description              = "Jenkins controller to kube-apiserver"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = var.jenkins_sg_id
    }
  }

  tags = {
    Name = "${var.project}-eks"
  }
}

# JNLP 50000 from the agent pods is an inline rule on the jenkins SG in modules/vpc.
# A standalone rule here was deleted by that SG's inline reconcile on every apply.


# pod idientity for the jenkins controller to be able to create agent pods in the eks cluster
resource "aws_iam_role" "jenkins_agent" {
  name = "${var.project}-jenkins-agent"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}


resource "aws_iam_role_policy_attachment" "jenkins_agent" {
  role       = aws_iam_role.jenkins_agent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_eks_pod_identity_association" "jenkins_agent" {
  cluster_name    = module.eks.cluster_name
  namespace       = "jenkins"
  service_account = "jenkins-agent"
  role_arn        = aws_iam_role.jenkins_agent.arn
}




# ---------- AWS Load Balancer Controller ----------


#reading the iam policy that i installed in the infestractioer model lbc-iam-policy.json
resource "aws_iam_policy" "lbc" {
  name        = "${var.project}-lbc"
  description = "AWS Load Balancer Controller"
  policy      = file("${path.module}/lbc-iam-policy.json")
}

resource "aws_iam_role" "lbc" {
  name = "${var.project}-lbc"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}


resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}

resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"


  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }


  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "replicaCount"
    value = "1"
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  depends_on = [aws_eks_pod_identity_association.lbc]
}


# ---------- EBS CSI driver IAM ----------
resource "aws_iam_role" "ebs_csi" {
  name = "${var.project}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}
