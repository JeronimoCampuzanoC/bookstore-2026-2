data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# AWS Academy: no se pueden crear roles; se reutiliza LabRole en todo.
data "aws_iam_role" "lab" {
  name = "LabRole"
}

locals {
  name = var.project
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  # /20 por subred: public 0-1, private (EKS) 2-3, db 4-5
  public_cidrs  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_cidrs = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i + 2)]
  db_cidrs      = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i + 4)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-igw" }
}

# ---------- Subredes ----------
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = local.public_cidrs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                      = "${local.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                  = "1"
    "kubernetes.io/cluster/${local.name}-eks" = "shared"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.private_cidrs[count.index]

  tags = {
    Name                                      = "${local.name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"         = "1"
    "kubernetes.io/cluster/${local.name}-eks" = "shared"
  }
}

resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.db_cidrs[count.index]
  tags              = { Name = "${local.name}-db-${local.azs[count.index]}" }
}

# ---------- NAT por AZ ----------
resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-${local.azs[count.index]}" }
}

resource "aws_nat_gateway" "this" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${local.name}-nat-${local.azs[count.index]}" }
  depends_on    = [aws_internet_gateway.this]
}

# ---------- Route tables ----------
resource "aws_route_table" "public" {
  count  = 2
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-public-rt-${local.azs[count.index]}" }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[count.index].id
}

resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-private-rt-${local.azs[count.index]}" }

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Subredes de BD: aisladas (sin ruta a Internet)
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-db-rt" }
}

resource "aws_route_table_association" "db" {
  count          = 2
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}
