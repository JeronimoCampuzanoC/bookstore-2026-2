# Microservicio -> archivo en emptyDir -> sidecar Fluent Bit -> CloudWatch Logs -> Lambda -> S3
# Sin IRSA ni Pod Identity: el sidecar usa las credenciales del rol del nodo
# (LabRole) vía IMDS (hop limit 2 en el launch template de los nodos).

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/${local.name}/eks"
  retention_in_days = var.log_retention_days
}

# El provider lee GetObjectLockConfiguration, denegado por una SCP de AWS Academy,
# así que el bucket se crea con la CLI (que sí tiene permiso).
locals {
  logs_bucket = "${local.name}-logs-${random_id.suffix.hex}"
}

resource "null_resource" "logs_bucket" {
  triggers = { name = local.logs_bucket, region = var.region }

  provisioner "local-exec" {
    command = "aws s3api create-bucket --bucket ${self.triggers.name} --region ${self.triggers.region} --create-bucket-configuration LocationConstraint=${self.triggers.region} || aws s3api head-bucket --bucket ${self.triggers.name}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "aws s3 rb s3://${self.triggers.name} --force --region ${self.triggers.region}"
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = null_resource.logs_bucket.triggers.name
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- Lambda (rol = LabRole) ----------
data "archive_file" "log_shipper" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/.build/log_shipper.zip"
}

resource "aws_lambda_function" "log_shipper" {
  function_name    = "${local.name}-log-shipper"
  role             = data.aws_iam_role.lab.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.log_shipper.output_path
  source_code_hash = data.archive_file.log_shipper.output_base64sha256
  timeout          = 30

  environment {
    variables = { BUCKET = local.logs_bucket }
  }
}

resource "aws_lambda_permission" "from_logs" {
  statement_id  = "AllowCloudWatchLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.log_shipper.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.backend.arn}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "to_lambda" {
  name            = "${local.name}-to-s3"
  log_group_name  = aws_cloudwatch_log_group.backend.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.log_shipper.arn
  depends_on      = [aws_lambda_permission.from_logs]
}

# ---------- Configuración del sidecar Fluent Bit (la usan todos los microservicios) ----------
# Un log stream por Pod: ${HOSTNAME} es el nombre del Pod (p. ej. order-service-7c9d...).
resource "kubernetes_config_map_v1" "sidecar" {
  metadata {
    name      = "fluent-bit-sidecar"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  data = {
    "fluent-bit.conf" = <<-EOT
      [SERVICE]
          Flush        5
          Log_Level    info

      [INPUT]
          Name              tail
          Path              /logs/clickstream.log
          Tag               clickstream
          Refresh_Interval  5

      [OUTPUT]
          Name              cloudwatch_logs
          Match             *
          region            ${var.region}
          log_group_name    ${aws_cloudwatch_log_group.backend.name}
          log_stream_name   $${HOSTNAME}
          auto_create_group Off
    EOT
  }
}
