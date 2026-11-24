locals {
  namespace = "bookstore"

  backend_env = {
    NODE_ENV                     = "production"
    PORT                         = "5001"
    API_BASE_PATH                = "/api"
    CORS_ORIGINS                 = var.frontend_url
    BOOKS_DEFAULT_LIMIT          = "24"
    BOOKS_MAX_LIMIT              = "100"
    ORDERS_MAX_DISTINCT_ITEMS    = "100"
    ORDERS_MAX_QUANTITY_PER_ITEM = "1000"
    HTTP_TRUST_PROXY_HOPS        = "2" # ALB + APISIX
    HTTP_JSON_BODY_LIMIT         = "32kb"
    ACCESS_LOG_ENABLED           = "true"
    ACCESS_LOG_EXCLUDE_PATHS     = "/health"
    ACCESS_LOG_MAX_FIELD_LENGTH  = "2048"
    ACCESS_LOG_REQUEST_ID_HEADER = "X-Request-Id"
    # El clickstream se escribe en un archivo (emptyDir) que lee el sidecar Fluent Bit.
    CLICKSTREAM_FILE_ENABLED = "true"
    CLICKSTREAM_FILE_PATH    = "/usr/src/app/logs/clickstream.log"

    DB_HOST                    = aws_db_instance.master.address
    DB_PORT                    = "5432"
    DB_NAME                    = local.db_name
    DB_USER                    = local.app_db_user
    DB_SSL                     = "true"
    DB_SSL_REJECT_UNAUTHORIZED = "false"
    DB_POOL_MAX                = "10"
    DB_IDLE_TIMEOUT_MS         = "30000"
    DB_CONNECTION_TIMEOUT_MS   = "5000"

    AUTH_JWT_ALGORITHM     = "HS256"
    AUTH_JWT_ISSUER        = "bookstore-api"
    AUTH_JWT_AUDIENCE      = "bookstore-web"
    AUTH_TOKEN_TTL_SECONDS = "28800"
    AUTH_COOKIE_NAME       = "bookstore_session"
    AUTH_COOKIE_SECURE     = "false" # el ALB solo expone HTTP
    AUTH_COOKIE_SAME_SITE  = "lax"
    AUTH_COOKIE_PATH       = "/api"
  }
}

resource "kubernetes_namespace_v1" "app" {
  metadata { name = local.namespace }
  depends_on = [aws_eks_node_group.this]
}

resource "kubernetes_secret_v1" "app" {
  metadata {
    name      = "app-secrets"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    DB_PASSWORD     = random_password.app_db.result
    AUTH_JWT_SECRET = random_password.jwt.result
  }
  depends_on = [kubernetes_namespace_v1.app]
}

# ---------- Bootstrap de la BD (Job dentro del cluster; RDS es privada) ----------
resource "kubernetes_config_map_v1" "db_sql" {
  metadata {
    name      = "db-bootstrap-sql"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    "bootstrap.sh"     = file("${var.app_source_dir}/database/rds/bootstrap.sh")
    "create_roles.sql" = file("${var.app_source_dir}/database/rds/create_roles.sql")
    "grants.sql"       = file("${var.app_source_dir}/database/rds/grants.sql")
    "verify.sql"       = file("${var.app_source_dir}/database/rds/verify.sql")
    "schema.sql"       = file("${var.app_source_dir}/database/schema.sql")
    "seed.sql"         = file("${var.app_source_dir}/database/seed.sql")
  }
  depends_on = [kubernetes_namespace_v1.app]
}

resource "kubernetes_secret_v1" "db_bootstrap" {
  metadata {
    name      = "db-bootstrap"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    DB_ADMIN_PASSWORD  = random_password.db_admin.result
    APP_DB_PASSWORD    = random_password.app_db.result
    INGEST_DB_PASSWORD = random_password.ingest_db.result
  }
  depends_on = [kubernetes_namespace_v1.app]
}

resource "kubernetes_job_v1" "db_bootstrap" {
  metadata {
    name      = "db-bootstrap"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  spec {
    backoff_limit = 4

    template {
      metadata { labels = { app = "db-bootstrap" } }

      spec {
        restart_policy = "OnFailure"

        container {
          name    = "bootstrap"
          image   = "postgres:17"
          command = ["/bin/bash", "/database/rds/bootstrap.sh"]

          env {
            name  = "DB_HOST"
            value = aws_db_instance.master.address
          }
          env {
            name  = "DB_PORT"
            value = "5432"
          }
          env {
            name  = "DB_NAME"
            value = local.db_name
          }
          env {
            name  = "DB_ADMIN_USER"
            value = local.db_admin_user
          }
          env {
            name  = "APP_DB_USER"
            value = local.app_db_user
          }
          env {
            name  = "INGEST_DB_USER"
            value = local.ingest_db_user
          }
          env {
            name  = "PGSSLMODE"
            value = "require"
          }
          env_from {
            secret_ref { name = kubernetes_secret_v1.db_bootstrap.metadata[0].name }
          }

          volume_mount {
            name       = "sql"
            mount_path = "/database"
            read_only  = true
          }
        }

        volume {
          name = "sql"
          config_map {
            name = kubernetes_config_map_v1.db_sql.metadata[0].name
            items {
              key  = "bootstrap.sh"
              path = "rds/bootstrap.sh"
            }
            items {
              key  = "create_roles.sql"
              path = "rds/create_roles.sql"
            }
            items {
              key  = "grants.sql"
              path = "rds/grants.sql"
            }
            items {
              key  = "verify.sql"
              path = "rds/verify.sql"
            }
            items {
              key  = "schema.sql"
              path = "schema.sql"
            }
            items {
              key  = "seed.sql"
              path = "seed.sql"
            }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "15m"
  }

  depends_on = [aws_db_instance.master]
}

# ---------- Microservicios (cada Pod = app + sidecar Fluent Bit) ----------
resource "kubernetes_deployment_v1" "service" {
  for_each = toset(local.services)

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = { app = each.key }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = { app = each.key }
    }

    template {
      metadata {
        labels = { app = each.key }
        annotations = {
          # Si cambia la configuración del sidecar, los Pods se reinician
          sidecar-config-hash = sha1(jsonencode(kubernetes_config_map_v1.sidecar.data))
        }
      }

      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = { app = each.key }
          }
        }

        # Contenedor principal: el microservicio
        container {
          name  = "app"
          image = "${aws_ecr_repository.service[each.key].repository_url}:${var.image_tag}"

          port {
            container_port = 5001
          }

          dynamic "env" {
            for_each = merge(local.backend_env, { SERVICE_NAME = each.key })
            content {
              name  = env.key
              value = env.value
            }
          }
          env_from {
            secret_ref { name = kubernetes_secret_v1.app.metadata[0].name }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 5001
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { memory = "512Mi" }
          }

          # Aquí escribe clickstream.log
          volume_mount {
            name       = "logs"
            mount_path = "/usr/src/app/logs"
          }
        }

        # Sidecar: lee el log del volumen compartido y lo envía a CloudWatch
        container {
          name  = "fluent-bit"
          image = var.fluent_bit_image

          resources {
            requests = { cpu = "20m", memory = "32Mi" }
            limits   = { memory = "128Mi" }
          }

          volume_mount {
            name       = "logs"
            mount_path = "/logs"
            read_only  = true
          }
          volume_mount {
            name       = "fluent-bit-config"
            mount_path = "/fluent-bit/etc/fluent-bit.conf"
            sub_path   = "fluent-bit.conf"
          }
        }

        # Volumen compartido entre la app y el sidecar (vive lo mismo que el Pod)
        volume {
          name = "logs"
          empty_dir {}
        }
        volume {
          name = "fluent-bit-config"
          config_map {
            name = kubernetes_config_map_v1.sidecar.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [null_resource.service_image, kubernetes_job_v1.db_bootstrap]
}

resource "kubernetes_service_v1" "service" {
  for_each = toset(local.services)

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  spec {
    type     = "ClusterIP"
    selector = { app = each.key }
    port {
      port        = 5001
      target_port = 5001
    }
  }
}

# ---------- API Gateway: APISIX en modo standalone (rutas en gateway/apisix.yaml) ----------
resource "kubernetes_config_map_v1" "apisix_routes" {
  metadata {
    name      = "apisix-routes"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    "apisix.yaml" = file("${var.app_source_dir}/gateway/apisix.yaml")
  }
}

resource "kubernetes_deployment_v1" "apisix" {
  metadata {
    name      = "apisix"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = { app = "apisix" }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = { app = "apisix" }
    }

    template {
      metadata {
        labels = { app = "apisix" }
        annotations = {
          # Si cambian las rutas, Kubernetes reinicia APISIX de forma gradual
          routes-hash = sha1(kubernetes_config_map_v1.apisix_routes.data["apisix.yaml"])
        }
      }

      spec {
        container {
          name  = "apisix"
          image = var.apisix_image

          # Modo standalone: sin etcd, lee las rutas de conf/apisix.yaml
          env {
            name  = "APISIX_STAND_ALONE"
            value = "true"
          }

          port {
            container_port = 9080
          }

          readiness_probe {
            tcp_socket {
              port = 9080
            }
            period_seconds = 10
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { memory = "512Mi" }
          }

          volume_mount {
            name       = "routes"
            mount_path = "/usr/local/apisix/conf/apisix.yaml"
            sub_path   = "apisix.yaml"
          }
        }

        volume {
          name = "routes"
          config_map {
            name = kubernetes_config_map_v1.apisix_routes.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubernetes_deployment_v1.service]
}

resource "kubernetes_service_v1" "apisix" {
  metadata {
    name      = "apisix-gateway"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  spec {
    type     = "ClusterIP"
    selector = { app = "apisix" }
    port {
      port        = 9080
      target_port = 9080
    }
  }
}

# ---------- ALB (aws-load-balancer-controller): todo el tráfico va a APISIX ----------
resource "kubernetes_ingress_v1" "web" {
  metadata {
    name      = "web-ingress"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    annotations = {
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/healthcheck-path" = "/"
      # APISIX responde 404 en "/" (no hay ruta), y eso basta para saber que está vivo
      "alb.ingress.kubernetes.io/success-codes" = "200-404"
    }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.apisix.metadata[0].name
              port { number = 9080 }
            }
          }
        }
      }
    }
  }

  wait_for_load_balancer = true
  depends_on             = [helm_release.alb_controller]
}
