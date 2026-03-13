version: 2
ethernets:
  enp1s0:
    addresses:
      - ${ip_address}/24
    routes:
      - to: default
        via: 192.168.122.1
    nameservers:
      addresses:
        - 192.168.122.1
