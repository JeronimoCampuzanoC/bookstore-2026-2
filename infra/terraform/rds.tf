locals {
  db_name        = "bookstore"
  db_admin_user  = "bookstore_admin"
  app_db_user    = "bookstore_app"
  ingest_db_user = "bookstore_ingest"
}

resource "random_password" "db_admin" {
  length  = 24
  special = false
}

resource "random_password" "app_db" {
  length  = 24
  special = false
}

resource "random_password" "ingest_db" {
  length  = 24
  special = false
}

resource "random_password" "jwt" {
  length  = 48
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.db[*].id
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "PostgreSQL desde las subredes privadas de EKS"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "PostgreSQL desde pods/nodos"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = local.private_cidrs
  }
}

# Master (AZ 1)
resource "aws_db_instance" "master" {
  identifier              = "${local.name}-master"
  engine                  = "postgres"
  engine_version          = "17"
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  storage_type            = "gp3"
  storage_encrypted       = true
  db_name                 = local.db_name
  username                = local.db_admin_user
  password                = random_password.db_admin.result
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  availability_zone       = local.azs[0]
  publicly_accessible     = false
  backup_retention_period = 1 # requerido para tener réplica
  skip_final_snapshot     = true
  apply_immediately       = true
}

# Follower (AZ 2): réplica de lectura
resource "aws_db_instance" "follower" {
  identifier             = "${local.name}-follower"
  replicate_source_db    = aws_db_instance.master.identifier
  instance_class         = var.db_instance_class
  storage_encrypted      = true
  vpc_security_group_ids = [aws_security_group.db.id]
  availability_zone      = local.azs[1]
  publicly_accessible    = false
  skip_final_snapshot    = true
  apply_immediately      = true
}

resource "random_id" "suffix" {
  byte_length = 4
}
