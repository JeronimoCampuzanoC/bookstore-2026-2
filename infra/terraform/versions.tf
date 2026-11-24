terraform {
  required_version = ">= 1.6"

  required_providers {
    aws        = { source = "hashicorp/aws", version = ">= 5.80" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    helm       = { source = "hashicorp/helm", version = "~> 2.17" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
    archive    = { source = "hashicorp/archive", version = "~> 2.7" }
    null       = { source = "hashicorp/null", version = "~> 3.2" }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = { Project = var.project, ManagedBy = "terraform" }
  }
}

locals {
  eks_auth_args = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.region]
}

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_auth_args
  }
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.eks_auth_args
    }
  }
}
