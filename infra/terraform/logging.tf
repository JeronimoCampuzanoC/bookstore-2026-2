# Pods -> Fluent Bit (DaemonSet) -> CloudWatch Logs -> Lambda -> S3
# Sin IRSA ni Pod Identity: Fluent Bit usa las credenciales del rol del nodo
# (LabRole) vía IMDS (hop limit 2 en el launch template de los nodos).

resource "kubernetes_namespace_v1" "logging" {
  metadata { name = "logging" }
  depends_on = [aws_eks_node_group.this]
}

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

# ---------- Fluent Bit ----------
resource "kubernetes_service_account_v1" "fluent_bit" {
  metadata {
    name      = "fluent-bit"
    namespace = kubernetes_namespace_v1.logging.metadata[0].name
  }
}

resource "kubernetes_cluster_role_v1" "fluent_bit" {
  metadata { name = "fluent-bit-read" }
  rule {
    api_groups = [""]
    resources  = ["pods", "namespaces"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "fluent_bit" {
  metadata { name = "fluent-bit-read" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.fluent_bit.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.fluent_bit.metadata[0].name
    namespace = kubernetes_namespace_v1.logging.metadata[0].name
  }
}

resource "kubernetes_config_map_v1" "fluent_bit" {
  metadata {
    name      = "fluent-bit-config"
    namespace = kubernetes_namespace_v1.logging.metadata[0].name
  }

  data = {
    "fluent-bit.conf" = <<-EOT
      [SERVICE]
          Flush        5
          Log_Level    info
          Daemon       Off
          Parsers_File parsers.conf

      [INPUT]
          Name              tail
          Tag               kube.*
          Path              /var/log/containers/*_${local.namespace}_*.log
          multiline.parser  docker, cri
          DB                /var/fluent-bit/state/flb_kube.db
          Mem_Buf_Limit     5MB
          Skip_Long_Lines   On
          Refresh_Interval  10

      [FILTER]
          Name                kubernetes
          Match               kube.*
          Kube_URL            https://kubernetes.default.svc:443
          Kube_Tag_Prefix     kube.var.log.containers.
          Merge_Log           On
          Keep_Log            Off
          K8S-Logging.Parser  Off
          K8S-Logging.Exclude Off
          Labels              On
          Annotations         Off

      [OUTPUT]
          Name              cloudwatch_logs
          Match             kube.*
          region            ${var.region}
          log_group_name    ${aws_cloudwatch_log_group.backend.name}
          log_stream_prefix pod-
          auto_create_group Off
    EOT
    "parsers.conf"    = "[PARSER]\n    Name   json\n    Format json\n"
  }
}

resource "kubernetes_daemon_set_v1" "fluent_bit" {
  metadata {
    name      = "fluent-bit"
    namespace = kubernetes_namespace_v1.logging.metadata[0].name
    labels    = { app = "fluent-bit" }
  }

  spec {
    selector {
      match_labels = { app = "fluent-bit" }
    }

    template {
      metadata {
        labels = { app = "fluent-bit" }
        annotations = {
          config-hash = sha1(jsonencode(kubernetes_config_map_v1.fluent_bit.data))
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.fluent_bit.metadata[0].name

        toleration {
          operator = "Exists"
        }

        container {
          name  = "fluent-bit"
          image = var.fluent_bit_image

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { memory = "200Mi" }
          }

          volume_mount {
            name       = "config"
            mount_path = "/fluent-bit/etc/fluent-bit.conf"
            sub_path   = "fluent-bit.conf"
          }
          volume_mount {
            name       = "config"
            mount_path = "/fluent-bit/etc/parsers.conf"
            sub_path   = "parsers.conf"
          }
          volume_mount {
            name       = "varlog"
            mount_path = "/var/log"
            read_only  = true
          }
          volume_mount {
            name       = "state"
            mount_path = "/var/fluent-bit/state"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.fluent_bit.metadata[0].name
          }
        }
        volume {
          name = "varlog"
          host_path { path = "/var/log" }
        }
        volume {
          name = "state"
          host_path {
            path = "/var/fluent-bit/state"
            type = "DirectoryOrCreate"
          }
        }
      }
    }
  }

  depends_on = [aws_cloudwatch_log_group.backend]
}
