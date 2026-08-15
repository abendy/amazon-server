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
    "git clone --depth 1 --branch '${var.server_branch}' https://github.com/abendy/amazon-server.git /opt/amazon-server",
    "exec bash /opt/amazon-server/infra/cloud-init.sh",
  ])

  tags = {
    Environment = "staging"
    ManagedBy   = "terraform"
    System      = "amazon-fyc"
  }
}

resource "aws_lightsail_static_ip" "staging" {
  name = var.static_ip_name
}

resource "aws_lightsail_static_ip_attachment" "staging" {
  static_ip_name = aws_lightsail_static_ip.staging.name
  instance_name  = aws_lightsail_instance.staging.name
}

resource "aws_lightsail_instance_public_ports" "staging" {
  instance_name = aws_lightsail_instance.staging.name

  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
  }

  port_info {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
  }

  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
  }
}
