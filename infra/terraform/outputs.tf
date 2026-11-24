output "app_url" {
  value = "http://${kubernetes_ingress_v1.web.status[0].load_balancer[0].ingress[0].hostname}"
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.region}"
}

output "logs_bucket" {
  value = local.logs_bucket
}

output "log_group" {
  value = aws_cloudwatch_log_group.backend.name
}

output "ecr_backend" {
  value = aws_ecr_repository.backend.repository_url
}

output "ecr_frontend" {
  value = aws_ecr_repository.frontend.repository_url
}

output "rds_master" {
  value = aws_db_instance.master.address
}

output "rds_follower" {
  value = aws_db_instance.follower.address
}
