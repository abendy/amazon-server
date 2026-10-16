provider "aws" {
  region = var.region
}

resource "aws_lightsail_instance" "staging" {
  name              = var.instance_name
  availability_zone = var.availability_zone
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id
  key_pair_name     = var.ssh_key_name
  ip_address_type   = "ipv4"
  user_data = join(" && ", [
    "set -eu",
    "export DEBIAN_FRONTEND=noninteractive",
    "apt-get update",
    "apt-get install -y ca-certificates git",
    "echo '${var.server_branch}' > /etc/amazon-server.ref",
    "echo '${var.environment}' > /etc/amazon-server.env",
    "git clone --depth 1 --branch '${var.server_branch}' https://github.com/abendy/amazon-server.git /opt/amazon-server",
    "exec bash /opt/amazon-server/infra/cloud-init.sh",
  ])

  # Daily automatic snapshots, when auto_snapshot_time is set. Declared here so
  # a plan never turns off snapshots enabled outside Terraform.
  dynamic "add_on" {
    for_each = var.auto_snapshot_time == null ? [] : [var.auto_snapshot_time]
    content {
      type          = "AutoSnapshot"
      snapshot_time = add_on.value
      status        = "Enabled"
    }
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    System      = "amazon-fyc"
  }

  # user_data runs once, at first boot; afterwards the instance follows
  # /etc/amazon-server.ref. Ignoring it lets tfvars change server_branch for
  # the next rebuild without planning a replacement. A deliberate user_data
  # change now needs -replace.
  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "aws_lightsail_static_ip" "staging" {
  name = var.static_ip_name
}

resource "aws_lightsail_static_ip_attachment" "staging" {
  static_ip_name = aws_lightsail_static_ip.staging.name
  instance_name  = aws_lightsail_instance.staging.name
}

# Each rule spells out the open-to-all ranges Lightsail stores. Left implicit,
# the provider plans to tear down and recreate every rule.
resource "aws_lightsail_instance_public_ports" "staging" {
  instance_name = aws_lightsail_instance.staging.name

  port_info {
    protocol          = "tcp"
    from_port         = 22
    to_port           = 22
    cidrs             = ["0.0.0.0/0"]
    ipv6_cidrs        = ["::/0"]
    cidr_list_aliases = []
  }

  port_info {
    protocol          = "tcp"
    from_port         = 80
    to_port           = 80
    cidrs             = ["0.0.0.0/0"]
    ipv6_cidrs        = ["::/0"]
    cidr_list_aliases = []
  }

  port_info {
    protocol          = "tcp"
    from_port         = 443
    to_port           = 443
    cidrs             = ["0.0.0.0/0"]
    ipv6_cidrs        = ["::/0"]
    cidr_list_aliases = []
  }
}
