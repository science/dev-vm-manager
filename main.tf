terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

# Base volume from cloud image (shared, read-only)
resource "libvirt_volume" "ubuntu_base" {
  name   = "ubuntu-noble-base.qcow2"
  pool   = "default"
  source = var.cloud_image_path
  format = "qcow2"
}

# Per-VM disk (backed by base volume, copy-on-write)
resource "libvirt_volume" "vm_disk" {
  for_each = var.vms

  name           = "${each.key}.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.ubuntu_base.id
  size           = var.disk_size_bytes
  format         = "qcow2"
}

# Cloud-init seed disk (user-data + network-config)
resource "libvirt_cloudinit_disk" "vm_cloudinit" {
  for_each = var.vms

  name = "${each.key}-cloudinit.iso"
  pool = "default"

  user_data = templatefile("${path.module}/cloud-init/user-data.tpl", {
    hostname   = each.key
    ssh_pubkey = trimspace(file(var.ssh_pubkey_path))
  })

  network_config = templatefile("${path.module}/cloud-init/network-config.tpl", {
    ip_address = each.value
  })
}

# VM domain
resource "libvirt_domain" "vm" {
  for_each = var.vms

  name   = each.key
  memory = var.ram_mb
  vcpus  = var.vcpus

  cloudinit = libvirt_cloudinit_disk.vm_cloudinit[each.key].id

  firmware = "/usr/share/OVMF/OVMF_CODE_4M.fd"

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.vm_disk[each.key].id
  }

  network_interface {
    network_name   = "default"
    wait_for_lease = false # using static IP, not DHCP
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }

  video {
    type = "virtio"
  }

  # virtiofs shared directories require shared memory
  memory {
    hugepages = false
  }

  xml {
    xslt = <<-XSLT
      <?xml version="1.0"?>
      <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" indent="yes"/>

        <!-- Identity transform: copy everything by default -->
        <xsl:template match="@*|node()">
          <xsl:copy>
            <xsl:apply-templates select="@*|node()"/>
          </xsl:copy>
        </xsl:template>

        <!-- Add memoryBacking for virtiofs -->
        <xsl:template match="/domain">
          <xsl:copy>
            <xsl:apply-templates select="@*|node()"/>
            <memoryBacking>
              <source type="memfd"/>
              <access mode="shared"/>
            </memoryBacking>
            <xsl:if test="not(devices/filesystem[@accessmode])">
              <!-- filesystems added below via devices template -->
            </xsl:if>
          </xsl:copy>
        </xsl:template>

        <!-- Add virtiofs filesystems to devices -->
        <xsl:template match="/domain/devices">
          <xsl:copy>
            <xsl:apply-templates select="@*|node()"/>
            <filesystem type="mount" accessmode="passthrough">
              <driver type="virtiofs"/>
              <source dir="${var.host_dev_dir}"/>
              <target dir="devmount"/>
            </filesystem>
            <filesystem type="mount" accessmode="passthrough">
              <driver type="virtiofs"/>
              <source dir="${var.host_pictures_dir}"/>
              <target dir="picsmount"/>
            </filesystem>
          </xsl:copy>
        </xsl:template>
      </xsl:stylesheet>
    XSLT
  }
}

# Manage /etc/hosts entries
resource "null_resource" "etc_hosts" {
  for_each = var.vms

  triggers = {
    vm_name = each.key
    vm_ip   = each.value
  }

  provisioner "local-exec" {
    command = "grep -q '${each.key}' /etc/hosts || echo '${each.value}  ${each.key}' | sudo tee -a /etc/hosts"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "sudo sed -i '/${self.triggers.vm_name}/d' /etc/hosts"
  }
}

# Clear SSH known_hosts on create
resource "null_resource" "ssh_keygen" {
  for_each = var.vms

  triggers = {
    vm_id = libvirt_domain.vm[each.key].id
  }

  provisioner "local-exec" {
    command = "ssh-keygen -R ${each.key} 2>/dev/null; ssh-keygen -R ${each.value} 2>/dev/null; true"
  }
}

# Outputs
output "vm_ips" {
  description = "VM name -> IP mapping"
  value       = var.vms
}

output "ssh_commands" {
  description = "SSH commands to connect"
  value = {
    for name, ip in var.vms : name => "ssh steve@${name}"
  }
}
