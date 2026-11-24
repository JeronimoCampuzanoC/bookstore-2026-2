locals {
  backend_dir  = "${var.app_source_dir}/backend"
  frontend_dir = "${var.app_source_dir}/frontend"
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"

  backend_image  = "${aws_ecr_repository.backend.repository_url}:${var.image_tag}"
  frontend_image = "${aws_ecr_repository.frontend.repository_url}:${var.image_tag}"

  backend_hash = sha1(join("", [
    for f in sort(fileset(local.backend_dir, "**")) :
    filesha1("${local.backend_dir}/${f}") if !strcontains(f, "node_modules")
  ]))
  frontend_hash = sha1(join("", [
    for f in sort(fileset(local.frontend_dir, "**")) :
    filesha1("${local.frontend_dir}/${f}") if !strcontains(f, "node_modules") && !startswith(f, "dist/")
  ]))
}

resource "aws_ecr_repository" "backend" {
  name         = "${local.name}-backend"
  force_delete = true
}

resource "aws_ecr_repository" "frontend" {
  name         = "${local.name}-frontend"
  force_delete = true
}

# Construyen (linux/amd64) y publican las imágenes en ECR.
resource "null_resource" "backend_image" {
  triggers = { src = local.backend_hash, tag = var.image_tag, repo = aws_ecr_repository.backend.repository_url }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${local.ecr_registry}
      docker build --platform linux/amd64 --build-arg NODE_IMAGE=node:24-alpine -t ${local.backend_image} ${local.backend_dir}
      docker push ${local.backend_image}
    EOT
  }
}

# SPA compilada con rutas relativas: el navegador llama a /api en el mismo ALB.
resource "null_resource" "frontend_image" {
  triggers = { src = local.frontend_hash, tag = var.image_tag, repo = aws_ecr_repository.frontend.repository_url }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${local.ecr_registry}
      docker build --platform linux/amd64 \
        --build-arg NODE_IMAGE=node:24-alpine \
        --build-arg NGINX_IMAGE=nginx:1.27-alpine \
        --build-arg VITE_API_BASE_URL=/ \
        --build-arg VITE_API_PREFIX=/api \
        --build-arg VITE_CURRENCY_LOCALE=${var.currency_locale} \
        --build-arg VITE_CURRENCY_CODE=${var.currency_code} \
        -t ${local.frontend_image} ${local.frontend_dir}
      docker push ${local.frontend_image}
    EOT
  }
}
