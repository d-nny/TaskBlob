# Server Deployment Guide

This guide outlines the steps to deploy your mail server configuration after pushing the Git repository to your server.

## 1. Prerequisites

- A server with Docker and Docker Compose installed
- Cloudflare account with API key (Global API Key)
- Domain name managed by Cloudflare

## 2. Server Setup Process

### 2.1. Push Repository to Server

```bash
# On your local machine
git add .
git commit -m "Updated server configuration with Cloudflare API integration"
git push

# On the server
git clone <your-repository-url> /var/server/config
cd /var/server/config
```

### 2.2. Configure Environment Variables

Create a `.env` file in the root directory of the repository on the server:

```bash
# On the server
cat > .env << EOF
CLOUDFLARE_EMAIL=your_cloudflare_email@example.com
CLOUDFLARE_API_KEY=your_cloudflare_global_api_key
POSTGRES_PASSWORD=secure_postgres_password
REDIS_PASSWORD=secure_redis_password
ROUNDCUBE_PASSWORD=secure_roundcube_password
DOMAIN=taskblob.com
EOF
```

Adjust the values for your specific configuration, especially:
- CLOUDFLARE_EMAIL - Your Cloudflare account email
- CLOUDFLARE_API_KEY - Your Cloudflare Global API Key
- DOMAIN - Your actual domain name

### 2.3. Start the Services

```bash
# On the server
cd /var/server/config
docker-compose up -d
```

This will start all the services defined in `docker-compose.yml` including:
- PostgreSQL database
- Redis cache
- Config API (for DNS management)
- Other supporting services

Wait for all services to start (about 30 seconds to 1 minute)

### 2.4. Run the Setup Script

```bash
# On the server
cd /var/server/config
chmod +x setup-dns.sh
./setup-dns.sh
```

This script will:
1. Generate DKIM keys
2. Create DNS records in Cloudflare
3. Set up mail domains and users
4. Generate SSL certificates
5. Configure all necessary services

### 2.5. Verify the Setup

After the script completes, verify the setup using the commands suggested at the end of the script:

```bash
# Check DNS records
dig +short MX taskblob.com

# Test SMTP connection
telnet mail.taskblob.com 25

# Test IMAP connection
openssl s_client -connect mail.taskblob.com:993

# Access webmail in your browser
https://webmail.taskblob.com
```

## 3. Troubleshooting

### 3.1. API Connection Issues

If the setup script fails to connect to the API:

```bash
# Check if the config-api container is running
docker ps | grep config-api

# Check the logs for errors
docker logs config-api
```

Make sure the API service is accessible at http://localhost:3000

### 3.2. DNS Issues

If DNS records don't appear to be updating:

```bash
# Check the API logs for Cloudflare API errors
docker logs config-api | grep "Failed to"

# Verify your Cloudflare API credentials
# Ensure your domain is properly managed by Cloudflare

# You can manually trigger DNS updates with:
curl -X POST http://localhost:3000/api/dns/taskblob.com/update
```

### 3.3. SSL Certificate Issues

If SSL certificate generation fails:

```bash
# Check if certbot is installed
which certbot

# If not installed, install it
apt-get update && apt-get install -y certbot python3-certbot-dns-cloudflare

# Run the certificate generation manually
# Find the script path from the setup output
sudo /tmp/generate-ssl.sh
```

### 3.4. Mail Service Issues

If mail services don't start correctly:

```bash
# Check mailserver container logs
docker logs mailserver

# Check if SSL certificates are correctly placed
ls -la ./ssl/taskblob.com/

# Check if DKIM keys are correctly placed
ls -la ./dkim/taskblob.com/

# Restart mail services
docker-compose restart mailserver
```

### 3.5. Webmail Access Issues

If you can't access the webmail interface:

```bash
# Check nginx container logs
docker logs nginx

# Check if the webmail container is running
docker ps | grep webmail

# Check webmail container logs
docker logs webmail

# Restart the webmail and nginx services
docker-compose restart webmail nginx
```

## 4. Firewall Configuration

Make sure your server's firewall allows the necessary ports:

```bash
# Run the firewall setup script if not already done
chmod +x setup-firewall.sh
./setup-firewall.sh

# Or manually configure the firewall to allow these ports:
# - 25, 465, 587 (SMTP)
# - 110, 995 (POP3)
# - 143, 993 (IMAP)
# - 80, 443 (HTTP/HTTPS)
```

## 5. Maintenance Tasks

### 5.1. SSL Certificate Renewal

SSL certificates from Let's Encrypt expire after 90 days. Set up a cron job to auto-renew:

```bash
# Create a renewal script
cat > ssl-renew.sh << EOF
#!/bin/bash
# Find and run the SSL renewal script
if [ -f /tmp/generate-ssl.sh ]; then
  sudo /tmp/generate-ssl.sh
else
  # If the original script isn't found, create a new one
  curl -X POST -H "Content-Type: application/json" \
    -d '{"email":"admin@taskblob.com","subdomains":["mail","webmail"]}' \
    http://localhost:3000/api/ssl/taskblob.com/generate
  
  # Wait for script to be created
  sleep 5
  
  # Run the newly created script
  if [ -f /tmp/generate-ssl.sh ]; then
    sudo /tmp/generate-ssl.sh
  fi
fi

# Restart services to use new certificates
docker-compose restart mailserver nginx
EOF

# Make it executable
chmod +x ssl-renew.sh

# Add to crontab to run monthly
echo "0 0 1 * * root cd /var/server/config && ./ssl-renew.sh" | sudo tee -a /etc/crontab
```

### 5.2. Backup Configuration

Set up regular backups of your configuration and data:

```bash
# Create a backup script
cat > backup.sh << EOF
#!/bin/bash
BACKUP_DIR="/var/backups/mailserver"
DATE=\$(date +%Y-%m-%d)

# Create backup directory
mkdir -p \$BACKUP_DIR

# Backup environment variables
cp .env \$BACKUP_DIR/env-\$DATE.bak

# Backup DNS configuration
docker exec postgres pg_dump -U postgres config > \$BACKUP_DIR/dns-config-\$DATE.sql

# Backup mail data
docker exec postgres pg_dump -U postgres mail > \$BACKUP_DIR/mail-\$DATE.sql

# Backup SSL certificates
tar -czf \$BACKUP_DIR/ssl-\$DATE.tar.gz ./ssl

# Backup DKIM keys
tar -czf \$BACKUP_DIR/dkim-\$DATE.tar.gz ./dkim

# Remove backups older than 30 days
find \$BACKUP_DIR -name "*.bak" -o -name "*.sql" -o -name "*.tar.gz" -mtime +30 -delete
EOF

# Make it executable
chmod +x backup.sh

# Add to crontab to run daily
echo "0 2 * * * root cd /var/server/config && ./backup.sh" | sudo tee -a /etc/crontab
```

### 5.3. Monitoring Mail Queue

To monitor the mail queue and address any delivery issues:

```bash
# Check mail queue
docker exec mailserver mailq

# Flush mail queue (force delivery attempt)
docker exec mailserver postqueue -f

# Delete all queued mail (use with caution)
docker exec mailserver postsuper -d ALL
```

### 5.4. Updating the System

To update the mail server system:

```bash
# Pull latest changes from repository
git pull

# Rebuild containers with new changes
docker-compose down
docker-compose build
docker-compose up -d

# Re-run setup if needed
./setup-dns.sh
```

## 6. Security Considerations

### 6.1. Change Default Passwords

After initial setup, immediately change default passwords:

1. Admin mail user password (via webmail interface)
2. PostgreSQL passwords in `.env` file
3. Redis password in `.env` file

### 6.2. Fail2ban Configuration

The fail2ban service is configured to protect against brute force attacks:

```bash
# Check fail2ban status
docker exec fail2ban fail2ban-client status

# Check specific jail status
docker exec fail2ban fail2ban-client status sshd
docker exec fail2ban fail2ban-client status postfix
```

### 6.3. Regular Security Updates

Keep the server secure with regular updates:

```bash
# Update the host system
apt update && apt upgrade -y

# Update Docker images
docker-compose pull
docker-compose up -d
```

## 7. Conclusion

Your mail server should now be fully operational with:

- Automated DNS management via Cloudflare API
- DKIM, SPF, and DMARC email authentication
- SSL encryption for all services
- PostgreSQL backend for mail accounts
- Webmail access for users
- Comprehensive security measures

For further assistance or customization, refer to the documentation in the repository or contact the system administrator.
