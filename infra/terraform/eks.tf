# EKS clásico + managed node group. Cluster role y node role = LabRole
# (AWS Academy no permite crear roles; LabRole tampoco soporta Auto Mode
# porque su trust policy no incluye sts:TagSession).
resource "aws_eks_cluster" "this" {
  name     = "${local.name}-eks"
  role_arn = data.aws_iam_role.lab.arn
  version  = var.kubernetes_version

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [aws_route_table_association.private, aws_nat_gateway.this]
}

# IMDS hop limit = 2 para que los pods (ALB controller, Fluent Bit) usen
# las credenciales del rol del nodo (LabRole) sin IRSA.
resource "aws_launch_template" "nodes" {
  name_prefix = "${local.name}-nodes-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name}-private"
  node_role_arn   = data.aws_iam_role.lab.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }
}

# ---------- AWS Load Balancer Controller (credenciales = rol del nodo) ----------
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.alb_controller_chart_version
  timeout    = 600

  set {
    name  = "clusterName"
    value = aws_eks_cluster.this.name
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = aws_vpc.this.id
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "replicaCount"
    value = "1"
  }

  depends_on = [aws_eks_node_group.this]
}
