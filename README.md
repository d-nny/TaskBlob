# Linux Server Build System

This repository contains scripts and configuration files for setting up a complete Linux server with mail, DNS management, and web services. All configuration is done through environment variables to avoid hardcoding sensitive information.

## Features

- Mail server setup with Postfix and Dovecot
- DNS management via Cloudflare API
- PostgreSQL database for mail accounts and web applications
- Web-based admin panel
- Centralized configuration management
- SSL certificate automation
- Firewall configuration

## Prerequisites

- A Linux server (Debian/Ubuntu recommended)
- Domain name with DNS managed by Cloudflare
- Docker and Docker Compose installed

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/d-nny/TaskBlob.git
   cd TaskBlob
   ```

2. Create a `.env` file from the template:
   ```bash
   cp .env.template .env
   ```

3. Initialize your credentials with a single master password:
   ```bash
   # Linux/Mac
   chmod +x init-credentials.js
   ./init-credentials.js
   
   # Windows
   node init-credentials.js
   ```

4. Run the master setup script:
   ```bash
   sudo ./master-setup.sh yourdomain.com
   ```

## Secure Credential Management

TaskBlob uses a master password system for enhanced security:

- You only need to remember **one master password**
- All service passwords are automatically generated with high entropy
- Service credentials are securely encrypted using AES-256-GCM
- The encrypted credentials file can be safely backed up

When you run `init-credentials.js`, the system will:
1. Ask for your master password
2. Generate strong random passwords for all services
3. Encrypt these passwords with your master password
4. Update the .env file to only contain the master password

This approach significantly improves security by:
- Eliminating weak/reused passwords
- Removing plaintext credentials from configuration files
- Providing a single point of authentication
- Making credential rotation simple

## Components

- **Mail Server**: Postfix, Dovecot, PostgreSQL backend
- **Admin Panel**: Web interface accessible at admin.yourdomain.com
- **Config API**: REST API for DNS and certificate management
- **Webmail**: Roundcube webmail interface
- **Nginx**: Reverse proxy for all web services
- **PostgreSQL**: Database for all services
- **Redis**: Caching and queuing

## Admin Panel

The admin panel provides a web interface for:

- Managing domains
- Managing mail accounts
- Viewing server status
- Monitoring logs
- Managing SSL certificates

Access it at https://admin.yourdomain.com after setup.

## Manual Scripts

Run individual setup components manually:

- `./setup-dns.sh yourdomain.com`: Configure DNS
- `./setup-firewall.sh`: Configure firewall rules
- `./setup-postgres.sh`: Set up PostgreSQL
- `./setup-mail.sh`: Configure mail server

## Security Notes

- All sensitive values are loaded from environment variables
- No hardcoded credentials are stored in the repository
- SSL certificates are automatically renewed
- Fail2ban is configured for basic protection

## Contributing

Pull requests are welcome. Please ensure that no sensitive or identifying information is included in your contributions.
