variable "region" {
  description = "AWS region for the Lightsail staging instance."
  type        = string
}

variable "availability_zone" {
  description = "Lightsail availability zone selected in the requested region."
  type        = string
}

variable "bundle_id" {
  description = "Lightsail bundle ID selected by the driver for staging."
  type        = string
}

variable "blueprint_id" {
  description = "Plain Ubuntu 24.04 Lightsail blueprint ID."
  type        = string
}

variable "instance_name" {
  description = "Unique Lightsail instance name in the selected region."
  type        = string
}

variable "static_ip_name" {
  description = "Unique Lightsail static IP name in the selected region."
  type        = string
}

variable "ssh_key_name" {
  description = "Existing Lightsail key-pair name for driver SSH access."
  type        = string
}

variable "server_branch" {
  description = "Branch of the public amazon-server repo the instance provisions from. Leave at develop except for a deliberate pre-land test build."
  type        = string
  default     = "develop"
}
