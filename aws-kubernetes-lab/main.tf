terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "http" {}

# Terraform detects the public IPv4 address of the machine running apply.
# This removes the need to manually discover and type your IP address.
data "http" "my_public_ip" {
  url = "https://checkip.amazonaws.com"
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  project_name = var.name

  # Use an explicitly supplied CIDR when provided; otherwise automatically
  # allow SSH only from the current public IP of the Terraform machine.
  detected_admin_cidr = "${chomp(data.http.my_public_ip.response_body)}/32"
  admin_cidr          = var.admin_cidr == null ? local.detected_admin_cidr : var.admin_cidr

  common_tags = {
    Project   = var.name
    ManagedBy = "Terraform"
    Purpose   = "Kubernetes learning lab"
  }
}

# -----------------------------
# Networking: VPC and subnets
# -----------------------------

resource "aws_vpc" "kubernetes_lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${local.project_name}-vpc"
  })
}

resource "aws_internet_gateway" "kubernetes_lab" {
  vpc_id = aws_vpc.kubernetes_lab.id

  tags = merge(local.common_tags, {
    Name = "${local.project_name}-igw"
  })
}

resource "aws_subnet" "public" {
  count = var.public_subnet_count

  vpc_id                  = aws_vpc.kubernetes_lab.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${local.project_name}-public-${count.index + 1}"
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.kubernetes_lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.kubernetes_lab.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.project_name}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = var.public_subnet_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------
# Security
# -----------------------------

resource "aws_security_group" "kubernetes_lab" {
  name_prefix = "${var.name}-"
  description = "Security group for the temporary K3s Kubernetes learning lab"
  vpc_id      = aws_vpc.kubernetes_lab.id

  ingress {
    description = "SSH from the Terraform operator public IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.admin_cidr]
  }

  # GitHub-hosted runners do not have one stable public IP range that can be
  # safely hard-coded. Keep this open only while the lab is running.
  ingress {
    description = "Kubernetes API for GitHub Actions"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.kubernetes_api_cidr]
  }

  ingress {
    description = "HTTP application access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS application access"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow outbound traffic for updates and image downloads"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-sg"
  })
}

# -----------------------------
# Kubernetes server
# -----------------------------

resource "aws_eip" "kubernetes_lab" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.name}-eip"
  })
}

resource "aws_instance" "kubernetes_lab" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public[0].id
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.kubernetes_lab.id]
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 25
    encrypted             = true
    delete_on_termination = true
  }

  user_data = <<-USERDATA
    #!/bin/bash
    set -euxo pipefail
    exec > >(tee -a /var/log/kubernetes-lab-bootstrap.log) 2>&1

    apt-get update -y
    apt-get install -y curl ca-certificates git

    # Single-node K3s keeps the lab inexpensive while preserving the
    # kubectl/kubeconfig flow used in the course.
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable=traefik --tls-san ${aws_eip.kubernetes_lab.public_ip} --write-kubeconfig-mode=644" sh -

    until kubectl get nodes >/dev/null 2>&1; do
      sleep 5
    done

    # K3s initially writes localhost in its kubeconfig. Replace it with the
    # stable Elastic IP so GitHub Actions can connect remotely.
    sed -i "s#https://127.0.0.1:6443#https://${aws_eip.kubernetes_lab.public_ip}:6443#g" /etc/rancher/k3s/k3s.yaml

    install -d -m 0755 /home/ubuntu/.kube
    cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
    chown -R ubuntu:ubuntu /home/ubuntu/.kube

    cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/kubeconfig
    chown ubuntu:ubuntu /home/ubuntu/kubeconfig

    kubectl get nodes > /home/ubuntu/k3s-ready.txt
  USERDATA

  tags = merge(local.common_tags, {
    Name = var.name
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eip_association" "kubernetes_lab" {
  instance_id   = aws_instance.kubernetes_lab.id
  allocation_id = aws_eip.kubernetes_lab.id
}

# -----------------------------
# Outputs
# -----------------------------

output "vpc_id" {
  description = "ID of the Terraform-created VPC"
  value       = aws_vpc.kubernetes_lab.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "detected_admin_cidr" {
  description = "CIDR automatically used for SSH"
  value       = local.admin_cidr
}

output "public_ip" {
  description = "Elastic IP of the K3s Kubernetes server"
  value       = aws_eip.kubernetes_lab.public_ip
}

output "api_server" {
  description = "Kubernetes API endpoint used by KUBECONFIG"
  value       = "https://${aws_eip.kubernetes_lab.public_ip}:6443"
}

output "ssh_command" {
  description = "SSH command for troubleshooting"
  value       = "ssh -i ${var.private_key_path} ubuntu@${aws_eip.kubernetes_lab.public_ip}"
}

output "kubeconfig_retrieval_command" {
  description = "Command to retrieve kubeconfig after cloud-init completes"
  value       = "ssh -i ${var.private_key_path} ubuntu@${aws_eip.kubernetes_lab.public_ip} 'cat /home/ubuntu/kubeconfig'"
}
