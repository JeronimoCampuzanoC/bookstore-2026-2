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
  default = "8.1.0"
}

variable "backend_replicas" {
  type    = number
  default = 2
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

variable "currency_locale" {
  type    = string
  default = "es-CO"
}

variable "currency_code" {
  type    = string
  default = "COP"
}
