#!/bin/bash

# Server Extras Setup Script
# This script installs and configures various services needed for a complete server environment
# Usage: ./setup-extras.sh

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Server details
SERVER_IP="136.243.2.232"
SERVER_IPV6="2a01:4f8:211:1c4b::1"
SERVER_ROOT="/var/server"
SCRIPTS_DIR="${SERVER_ROOT}/scripts"

# Ensure script directory exists
mkdir -p "${SCRIPTS_DIR}"

# Function to setup monitoring with Prometheus and Node Exporter
setup_monitoring() {
    echo -e "${GREEN}Setting up server monitoring tools...${NC}"
    
    # Install Node Exporter for system metrics
    if ! command -v node_exporter &> /dev/null; then
        echo "Installing Node Exporter..."
        
        # Download the latest Node Exporter
        cd /tmp
        NODE_EXPORTER_VERSION=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep tag_name | cut -d '"' -f 4)
        wget https://github.com/prometheus/node_exporter/releases/download/${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION#v}.linux-amd64.tar.gz
        
        # Extract and install
        tar xvfz node_exporter-*.tar.gz
        cd node_exporter-*
        cp node_exporter /usr/local/bin/
        
        # Create a system user for Node Exporter
        useradd --no-create-home --shell /bin/false node_exporter
        
        # Create a systemd service file
        cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=localhost:9100

[Install]
WantedBy=multi-user.target
EOF
        
        # Start and enable the service
        systemctl daemon-reload
        systemctl start node_exporter
        systemctl enable node_exporter
        
        echo "Node Exporter installed and running on port 9100"
    else
        echo "Node Exporter is already installed."
    fi
    
    # Setup basic monitoring dashboard with Netdata
    if ! command -v netdata &> /dev/null; then
        echo "Installing Netdata for real-time monitoring..."
        
        # Install Netdata using their auto-installer
        bash <(curl -Ss https://my-netdata.io/kickstart.sh) --dont-wait
        
        # Configure Netdata to only listen on localhost and the server IP
        cat > /etc/netdata/netdata.conf << EOF
[global]
    bind to = localhost ${SERVER_IP} [${SERVER_IPV6}]
EOF
        
        # Restart Netdata to apply changes
        systemctl restart netdata
        
        echo "Netdata installed and running on port 19999"
    else
        echo "Netdata is already installed."
    fi
    
    echo -e "${GREEN}Monitoring setup completed.${NC}"
}

# Function to setup logrotate for all server logs
setup_logrotate() {
    echo -e "${GREEN}Setting up logrotate for server logs...${NC}"
    
    # Ensure logrotate is installed
    apt-get update
    apt-get install -y logrotate
    
    # Create a custom logrotate configuration for all server logs
    cat > /etc/logrotate.d/server-logs << EOF
/var/log/nginx/*.log
/var/log/postgresql/*.log
/var/log/mail.log
/var/log/mail.err
/var/log/mail.warn
/var/log/mail.info
/var/log/redis/redis-server.log
{
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        if [ -f /var/run/nginx.pid ]; then
            kill -USR1 \$(cat /var/run/nginx.pid)
        fi
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then
            run-parts /etc/logrotate.d/httpd-prerotate
        fi
        systemctl reload rsyslog >/dev/null 2>&1 || true
    endscript
}
EOF
    
    echo -e "${GREEN}Logrotate setup completed.${NC}"
}

# Function to setup system security enhancements
setup_security() {
    echo -e "${GREEN}Setting up additional security measures...${NC}"
    
    # Install security packages
    apt-get update
    apt-get install -y fail2ban rkhunter lynis unattended-upgrades apt-listchanges
    
    # Setup fail2ban for SSH
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]