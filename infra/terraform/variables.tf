variable "region" {
  description = "AWS Academy solo permite us-east-1 y us-west-2."
  type        = string
  default     = "us-west-2"
}

variable "project" {
  type    = string
  default = "bookstore"
}

variable "vpc_cidr" {
  type    = string
  default = "172.16.0.0/16"
}

variable "kubernetes_version" {
  description = "null = versión por defecto de EKS."
  type        = string
  default     = null
}

variable "app_source_dir" {
  description = "Ruta a la aplicación BookStore (frontend/, backend/, database/), relativa a infra/terraform."
  type        = string
  default     = "../.."
}

variable "image_tag" {
  type    = string
  default = "1.0.0"
}

variable "replicas" {
  description = "Réplicas de cada microservicio y de APISIX."
  type        = number
  default     = 2
}

variable "frontend_url" {
  description = "URL de Cloudflare Pages donde vive la SPA (origen permitido por CORS)."
  type        = string
  default     = "https://bookstore-2026-2.pages.dev"
}

variable "apisix_image" {
  type    = string
  default = "apache/apisix:3.11.0-debian"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "fluent_bit_image" {
  type    = string
  default = "public.ecr.aws/aws-observability/aws-for-fluent-bit:stable"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "alb_controller_chart_version" {
  type    = string
  default = "3.6.1"
}
