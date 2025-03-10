# Hetzner Server Compatibility Guide

This document outlines how to ensure TaskBlob works correctly with an existing Hetzner server configuration, particularly with the specific network setup and existing user accounts.

## Network Configuration Compatibility

The existing Hetzner network configuration:

```yaml
### Hetzner Online GmbH installimage
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s31f6:
      addresses:
        - 136.243.2.242/32
        - 136.243.2.234/32
        - 136.243.2.232/32
        - 2a01:4f8:211:1c4b::1/64
        - 2a01:4f8:211:1c4b::2/64
      routes:
        - on-link: true
          to: 0.0.0.0/0
          via: 136.243.2.193
        - to: default
          via: fe80::1
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
```

This network configuration is compatible with TaskBlob, since:

1. TaskBlob runs in Docker containers with their own networking
2. The server's physical network interfaces are accessible to Docker
3. The setup doesn't modify your existing network configuration

You should update the `.env` file to reference your specific IP addresses:

```
PRIMARY_IP=136.243.2.232
MAIL_IP=136.243.2.234
IPV6_PREFIX=2a01:4f8:211:1c4b
```

## Hosts File Configuration

Your current `/etc/hosts` configuration:

```
127.0.0.1 localhost
127.0.1.1 mail.taskblob.com mail
136.243.2.232 mail.taskblob.com mail
```

This hosts file configuration is compatible with TaskBlob, and actually helps ensure the mail server can find itself correctly. The setup scripts will not modify your `/etc/hosts` file unless specifically requested.

When setting up a new domain, you might want to update the hosts file to include:

```
136.243.2.232 admin.yourdomain.com webmail.yourdomain.com yourdomain.com
```

But this is not strictly necessary since DNS should handle external resolution.

## Existing User Accounts

### WinRemote Samba User

TaskBlob will NOT interfere with the existing `WinRemote` Samba user or its access to the `/var` directory. The installation:

1. Creates dedicated Docker volumes rather than directly using host directories
2. Does not modify existing host users or permissions
3. Does not reconfigure Samba

To ensure continued access for the `WinRemote` user, you should:

1. Add this user to the `docker` group if you want it to be able to manage Docker:
   ```bash
   sudo usermod -aG docker WinRemote
   ```

2. If you're concerned about file permissions, you can map Docker volumes to locations accessible by the `WinRemote` user by modifying `docker-compose.yml`:

   ```yaml
   volumes:
     mail_data:
       driver: local
       driver_opts:
         type: none
         device: /path/accessible/by/WinRemote
         o: bind
   ```

## Firewall Considerations

The setup-firewall.sh script by default creates rules that allow:

- SSH access (port 22)
- HTTP/HTTPS (ports 80/443)
- Mail protocols (ports 25, 465, 587, 110, 995, 143, 993)
- DNS (port 53)

To ensure the `WinRemote` user maintains access:

1. Add an explicit exception for Samba ports in the firewall script:

```bash
# Add to setup-firewall.sh
# Allow Samba access
ufw allow 139/tcp
ufw allow 445/tcp
```

2. If the `WinRemote` user connects from specific IP addresses, you can allow them:

```bash
# Replace 192.168.1.0/24 with the actual network range
ufw allow from 192.168.1.0/24 to any
```

## Docker Network Binding

By default, Docker containers will bind to all IP addresses (0.0.0.0). If you want to restrict which of your multiple IPs the services bind to, you can modify the ports section in `docker-compose.yml`:

```yaml
ports:
  - "136.243.2.232:80:80"
  - "136.243.2.232:443:443"
  - "136.243.2.234:25:25"
  # etc.
```

This ensures the web services use your main IP and mail services use your dedicated mail IP.

## IPv6 Configuration

Your Hetzner setup includes IPv6 addresses. To enable IPv6 in Docker:

1. Add the following to `/etc/docker/daemon.json` (create if it doesn't exist):

```json
{
  "ipv6": true,
  "fixed-cidr-v6": "fd00::/80"
}
```

2. Restart Docker:

```bash
sudo systemctl restart docker
```

3. Make sure your docker-compose.yml includes IPv6 configuration:

```yaml
networks:
  server_net:
    driver: bridge
    enable_ipv6: true
    ipam:
      config:
        - subnet: fd00::/80
```

## Conclusion

TaskBlob is compatible with your existing Hetzner server configuration. The Docker-based setup runs alongside existing services without interference, and the firewall can be configured to maintain existing access patterns.

When running the installation:

1. Use your actual IP addresses in the `.env` file
2. Modify firewall rules to maintain Samba access
3. Consider IPv6 configuration if you need IPv6 for your containers

These adjustments will ensure TaskBlob works correctly on your Hetzner server without disrupting existing functionality.
