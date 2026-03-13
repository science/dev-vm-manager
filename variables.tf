variable "vms" {
  description = "Map of VM name to IP address"
  type        = map(string)
  default = {
    "dev-1" = "192.168.122.101"
    "dev-2" = "192.168.122.102"
  }
}

variable "ram_mb" {
  description = "RAM in MiB"
  type        = number
  default     = 8192
}

variable "vcpus" {
  description = "Number of vCPUs"
  type        = number
  default     = 4
}

variable "disk_size_bytes" {
  description = "Disk size in bytes (40 GB)"
  type        = number
  default     = 42949672960 # 40 * 1024^3
}

variable "cloud_image_path" {
  description = "Path to Ubuntu cloud image"
  type        = string
  default     = "/home/steve/.cache/cloud-images/noble-server-cloudimg-amd64.img"
}

variable "ssh_pubkey_path" {
  description = "Path to SSH public key"
  type        = string
  default     = "/home/steve/.ssh/id_ed25519.pub"
}

variable "host_dev_dir" {
  description = "Host directory to share as ~/dev via virtiofs"
  type        = string
  default     = "/home/steve/dev"
}

variable "host_pictures_dir" {
  description = "Host directory to share as ~/Pictures via virtiofs"
  type        = string
  default     = "/home/steve/Pictures"
}
