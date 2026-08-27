# -----------------------------------------------------------------------------
# Networking (D-37, T-3.1)
#
# Exists only because Redshift Serverless requires a VPC with subnets in at
# least three availability zones. Nothing here faces the internet:
#
#   - no internet gateway, no NAT gateway. A NAT bills by the hour, forever, in
#     an environment designed to idle at close to zero (D-39).
#   - S3 reachable through a gateway endpoint, which is free.
#   - the Redshift Data API is an AWS API call, not VPC traffic, so no inbound
#     access is needed from anywhere.
# -----------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name      = "${local.name_prefix}-vpc"
    Component = "network"
  }
}

# Redshift Serverless requires three AZs.
resource "aws_subnet" "private" {
  count = 3

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name      = "${local.name_prefix}-private-${data.aws_availability_zones.available.names[count.index]}"
    Component = "network"
    Tier      = "private"
  }
}

# No default route: there is nowhere off-VPC to go except the S3 endpoint.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name      = "${local.name_prefix}-private"
    Component = "network"
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Gateway endpoint, not interface: free, and the only S3 path this VPC has.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name      = "${local.name_prefix}-s3"
    Component = "network"
  }
}

data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${var.aws_region}.s3"
}

# No ingress at all. Redshift is reached through the Data API, which does not
# traverse this VPC; egress is limited to S3 so COPY and UNLOAD can work.
resource "aws_security_group" "redshift" {
  name        = "${local.name_prefix}-redshift"
  description = "Redshift Serverless. No ingress; egress to S3 only."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name      = "${local.name_prefix}-redshift"
    Component = "network"
  }
}

resource "aws_vpc_security_group_egress_rule" "redshift_s3" {
  security_group_id = aws_security_group.redshift.id
  description       = "HTTPS to S3 via the gateway endpoint, for COPY and UNLOAD."

  ip_protocol    = "tcp"
  from_port      = 443
  to_port        = 443
  prefix_list_id = data.aws_ec2_managed_prefix_list.s3.id
}

# The default security group is unused; leave it explicitly empty rather than
# inheriting whatever AWS created.
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name      = "${local.name_prefix}-default-do-not-use"
    Component = "network"
  }
}
