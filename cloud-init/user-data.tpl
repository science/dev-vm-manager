#cloud-config
hostname: ${hostname}
timezone: America/New_York
users:
  - name: steve
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: "REDACTED_HASH"
    ssh_authorized_keys:
      - ${ssh_pubkey}
package_update: true
packages:
  - cinnamon-desktop-environment
  - lightdm
  - slick-greeter
  - gnome-terminal
  - spice-vdagent
  - openssh-server
write_files:
  - path: /etc/lightdm/lightdm.conf.d/90-autologin.conf
    content: |
      [Seat:*]
      autologin-user=steve
      autologin-session=cinnamon
runcmd:
  - mkdir -p /home/steve/dev /home/steve/Pictures
  - chown steve:steve /home/steve/dev /home/steve/Pictures
  - |
    if ! grep -q devmount /etc/fstab; then
      echo "devmount  /home/steve/dev       virtiofs defaults,nofail 0 0" >> /etc/fstab
      echo "picsmount /home/steve/Pictures  virtiofs defaults,nofail 0 0" >> /etc/fstab
    fi
  - mount -a || true
  - systemctl set-default graphical.target
