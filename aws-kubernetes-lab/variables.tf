variable "aws_region" {
  description = "AWS region for the Kubernetes lab"
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Prefix used for AWS resource names"
  type        = string
  default     = "solar-system-k8s-lab"
}

variable "vpc_cidr" {
  description = "CIDR block for the Terraform-created VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_count" {
  description = "Number of public subnets to create"
  type        = number
  default     = 2

  validation {
    condition     = var.public_subnet_count >= 2 && var.public_subnet_count <= 3
    error_message = "public_subnet_count must be between 2 and 3 for this lab."
  }
}

variable "instance_type" {
  description = "EC2 size for the single-node K3s lab"
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "Existing EC2 Key Pair name in the selected AWS region"
  type        = string
  default     = "ci-cd-key"

  validation {
    condition     = length(trimspace(var.key_name)) > 0
    error_message = "key_name must be the name of an existing EC2 Key Pair."
  }
}

variable "private_key_path" {
  description = "Local path to the private key used for SSH; Terraform only prints it in an output"
  type        = string
  default     = "./ci-cd-key"
}

variable "admin_cidr" {
  description = "Optional SSH source CIDR. Leave null to detect the current public IP automatically."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.admin_cidr == null || can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr must be null or a valid IPv4 CIDR, preferably /32."
  }
}

variable "kubernetes_api_cidr" {
  description = "CIDR allowed to reach K3s API port 6443. Keep 0.0.0.0/0 only for this temporary GitHub Actions lab."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.kubernetes_api_cidr, 0))
    error_message = "kubernetes_api_cidr must be a valid IPv4 CIDR."
  }
}
