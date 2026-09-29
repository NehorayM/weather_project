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
  # the API is private: scripts/tunnel.sh forwards 127.0.0.1:8443 to it through SSM.
  # tls_server_name keeps the certificate check on the real EKS hostname, so no /etc/hosts entry
  host                   = "https://127.0.0.1:8443"
  tls_server_name        = trimprefix(module.infrastructure.cluster_endpoint, "https://")
  cluster_ca_certificate = base64decode(module.infrastructure.cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.infrastructure.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = "https://127.0.0.1:8443"
    tls_server_name        = trimprefix(module.infrastructure.cluster_endpoint, "https://")
    cluster_ca_certificate = base64decode(module.infrastructure.cluster_ca)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.infrastructure.cluster_name, "--region", var.region]
    }
  }
}
