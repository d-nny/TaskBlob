# TaskBlob: Unified Server Deployment System

TaskBlob is a comprehensive mail and DNS server management system with an automated deployment process. This repository contains all necessary components for setting up a complete server environment with mail, DNS management, and administrative capabilities.

## Simplified Deployment Process

The deployment process has been completely redesigned to be more streamlined and user-friendly:

1. **Single Command Deployment**: Deploy the entire system with a single script
2. **First-Time Setup Wizard**: Configure admin password, DNS, and database through a web interface
3. **Consolidated Configuration**: All components work seamlessly together without manual intervention

## Getting Started

### Prerequisites

- A Linux server (Debian/Ubuntu recommended)
- Docker and Docker Compose installed
- Domain name with DNS managed by Cloudflare
- Server with port 25, 80, 443, and mail ports accessible

### Deployment

1. Clone the repository:
   ```bash
   git clone https://github.com/your-username/TaskBlob.git
   cd TaskBlob
   ```

2. Run the unified deployment script:
   ```bash
   ./deploy.sh
   ```

3. Access the admin panel at:
   - http://your-server-ip:3001
   - http://admin.yourdomain.com (once DNS is configured)

4. Complete the first-time setup wizard:
   - Set your admin password
   - Configure DNS settings
   - Initialize the database schema

## System Components

TaskBlob consists of the following key components:

### Docker Containers

- **PostgreSQL**: Database for mail, DNS config, and other data
- **Redis**: Caching and queueing service
- **Mailserver**: Postfix and Dovecot with PostgreSQL backend
- **Webmail**: Roundcube webmail interface
- **Config API**: REST API for DNS and certificate management
- **Admin Panel**: Web interface for server management
- **Nginx**: Reverse proxy for all web services
- **ClamAV**: Antivirus scanning
- **Fail2ban**: Intrusion prevention

### Key Files

- **deploy.sh**: Main deployment script to start all containers
- **docker-compose.yml**: Docker container configuration
- **cleanup.sh**: Utility to remove legacy scripts (run after confirming everything works)
- **.env**: Environment variables for service configuration

## Admin Panel Features

The admin panel provides a web interface for:

- Managing mail domains and accounts
- DNS record configuration
- SSL certificate management
- Server monitoring and logs
- System settings

## First-Time Setup Wizard

The wizard guides you through:

1. Setting a secure admin password
2. Configuring your domain and Cloudflare API credentials
3. Initializing the database schema
4. Getting started with your new server

## Secure Credential Management

TaskBlob uses a master password system for enhanced security:

- Set a single master password for admin access
- Service passwords are securely stored in the database
- All credentials are managed through the admin panel
- No plaintext passwords in configuration files

## Troubleshooting

If you encounter issues during deployment:

1. Check container logs:
   ```bash
   docker logs admin-panel
   docker logs postgres
   ```

2. Verify database connectivity:
   ```bash
   docker exec postgres pg_isready -U postgres
   ```

3. Check the admin panel is accessible:
   ```bash
   curl http://localhost:3001/login
   ```

## Contributing

Pull requests are welcome. Please ensure that no sensitive or identifying information is included in your contributions.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
