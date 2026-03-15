version: 2
ethernets:
  $NIC_NAME:
    addresses:
      - $IP_ADDRESS/24
    routes:
      - to: default
        via: $GATEWAY
    nameservers:
      addresses:
        - $DNS
