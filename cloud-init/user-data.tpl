#cloud-config
hostname: $VM_HOSTNAME
timezone: America/New_York
users:
  - name: steve
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: "REDACTED_HASH"
    ssh_authorized_keys:
      - $SSH_PUBKEY
apt:
  proxy: $APT_PROXY_URL
package_update: true
packages:
  - openssh-server
