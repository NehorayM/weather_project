terraform {
  required_version = ">= 1.6"

  required_providers {
    # add helm
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }

  }
}

provider "aws" {
  region = var.region
}


provider "kubernetes" {
  host                   = "${module.infrastructure.cluster_endpoint}:8443"
  cluster_ca_certificate = base64decode(module.infrastructure.cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.infrastructure.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = "${module.infrastructure.cluster_endpoint}:8443"
    cluster_ca_certificate = base64decode(module.infrastructure.cluster_ca)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.infrastructure.cluster_name, "--region", var.region]
    }
  }
}
