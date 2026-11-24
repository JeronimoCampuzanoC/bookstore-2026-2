locals {
  # Un microservicio por carpeta en services/
  services     = ["auth-service", "catalog-service", "order-service", "events-service"]
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

resource "aws_ecr_repository" "service" {
  for_each     = toset(local.services)
  name         = "${local.name}-${each.key}"
  force_delete = true
}

# Login a ECR una sola vez (si cada imagen hace su propio login al mismo tiempo,
# chocan en el llavero de macOS).
resource "null_resource" "ecr_login" {
  triggers = { always = timestamp() }

  provisioner "local-exec" {
    command = "aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${local.ecr_registry}"
  }
}

# Construye (linux/amd64) y publica la imagen de cada microservicio en ECR.
# Se vuelve a construir si cambia algún archivo de la carpeta del servicio.
resource "null_resource" "service_image" {
  for_each   = toset(local.services)
  depends_on = [null_resource.ecr_login]

  triggers = {
    src = sha1(join("", [
      for f in sort(fileset("${var.app_source_dir}/services/${each.key}", "**")) :
      filesha1("${var.app_source_dir}/services/${each.key}/${f}") if !strcontains(f, "node_modules")
    ]))
    tag  = var.image_tag
    repo = aws_ecr_repository.service[each.key].repository_url
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      docker build --platform linux/amd64 --build-arg NODE_IMAGE=node:24-alpine -t ${aws_ecr_repository.service[each.key].repository_url}:${var.image_tag} ${var.app_source_dir}/services/${each.key}
      docker push ${aws_ecr_repository.service[each.key].repository_url}:${var.image_tag}
    EOT
  }
}
