#!/bin/bash

# Redis Installation and Configuration Script
# Usage: ./setup-redis.sh [password]

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Configuration variables
REDIS_CONF="/etc/redis/redis.conf"
REDIS_LISTEN_ADDRESSES="127.0.0.1 136.243.2.232"  # Space-separated list
EXTERNAL_IP="136.243.2.232"
REDIS_PORT="6379"

# Check if password is provided or generate one
if [ $# -eq 1 ]; then
    REDIS_PASSWORD=$1
else
    # Generate a secure random password
    REDIS_PASSWORD=$(openssl rand -base64 16)
    echo -e "${YELLOW}No password provided. Generated password: ${REDIS_PASSWORD}${NC}"
    echo "Save this password in a secure location!"
fi

# Function to install Redis
install_redis() {
    echo -e "${GREEN}Installing Redis...${NC}"
    
    # Update package lists and install Redis
    apt-get update
    apt-get install -y redis-server
    
    # Verify installation
    if systemctl is-active --quiet redis-server; then
        echo -e "${GREEN}Redis installed successfully.${NC}"
    else
        echo -e "${RED}Redis installation failed.${NC}"
        exit 1
    fi
}

# Function to configure Redis networking
configure_network() {
    echo -e "${GREEN}Configuring Redis network settings...${NC}"
    
    # Stop Redis service
    systemctl stop redis-server
    
    # Backup original redis.conf
    cp "$REDIS_CONF" "${REDIS_CONF}.bak"
    
    # Configure Redis to listen on specific IPs
    sed -i "s/^bind .*/bind ${REDIS_LISTEN_ADDRESSES}/" "$REDIS_CONF"
    
    # Set protected mode to yes (requires password for remote connections)
    sed -i "s/^# protected-mode yes/protected-mode yes/" "$REDIS_CONF"
    
    # Set password
    if grep -q "^requirepass" "$REDIS_CONF"; then
        sed -i "s/^requirepass .*/requirepass ${REDIS_PASSWORD}/" "$REDIS_CONF"
    else
        echo "requirepass ${REDIS_PASSWORD}" >> "$REDIS_CONF"
    fi
    
    # Enable AOF for data persistence
    sed -i "s/^appendonly no/appendonly yes/" "$REDIS_CONF"
    
    # Start Redis service
    systemctl start redis-server
    
    echo -e "${GREEN}Redis network configuration updated.${NC}"
}

# Function to tune Redis performance
tune_redis() {
    echo -e "${GREEN}Tuning Redis performance...${NC}"
    
    # Get system memory
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
    
    # Set Redis memory limit to 25% of system memory
    REDIS_MEMORY_LIMIT=$((TOTAL_MEM_MB / 4))
    
    # Update Redis configuration
    sed -i "s/^# maxmemory .*/maxmemory ${REDIS_MEMORY_LIMIT}mb/" "$REDIS_CONF"
    sed -i "s/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/" "$REDIS_CONF"
    
    # Additional performance settings
    cat >> "$REDIS_CONF" << EOF

# Added performance tuning parameters
tcp-keepalive 60
tcp-backlog 511
timeout 0
databases 16
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /var/lib/redis
EOF
    
    # Restart Redis to apply changes
    systemctl restart redis-server
    
    echo -e "${GREEN}Redis performance tuning completed.${NC}"
}

# Function to setup firewall rules for Redis
setup_firewall_rules() {
    echo -e "${GREEN}Setting up firewall rules for Redis...${NC}"
    
    # Check which firewall is in use
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        echo "Configuring UFW firewall..."
        # Allow Redis connections from localhost
        ufw allow from 127.0.0.1 to any port $REDIS_PORT
        # Allow Redis connections from the specific external IP
        ufw allow from $EXTERNAL_IP to any port $REDIS_PORT
        
    elif command -v firewall-cmd &> /dev/null && firewall-cmd --state | grep -q "running"; then
        echo "Configuring FirewallD firewall..."
        # Allow Redis connections
        firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"127.0.0.1\" port protocol=\"tcp\" port=\"$REDIS_PORT\" accept"
        firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"$EXTERNAL_IP\" port protocol=\"tcp\" port=\"$REDIS_PORT\" accept"
        firewall-cmd --reload
        
    elif command -v iptables &> /dev/null; then
        echo "Configuring iptables firewall..."
        # Allow Redis connections from localhost
        iptables -A INPUT -p tcp -s 127.0.0.1 --dport $REDIS_PORT -j ACCEPT
        # Allow Redis connections from the specific external IP
        iptables -A INPUT -p tcp -s $EXTERNAL_IP --dport $REDIS_PORT -j ACCEPT
        
        # Save iptables rules
        if command -v iptables-save &> /dev/null; then
            iptables-save > /etc/iptables/rules.v4
        fi
    else
        echo -e "${YELLOW}No active firewall detected. Consider setting up a firewall.${NC}"
    fi
    
    echo -e "${GREEN}Firewall rules for Redis configured.${NC}"
}

# Function to check Redis status
check_redis_status() {
    echo -e "${GREEN}Checking Redis status...${NC}"
    
    # Check if Redis is running
    if systemctl is-active --quiet redis-server; then
        echo -e "${GREEN}Redis is running.${NC}"
    else
        echo -e "${RED}Redis is not running.${NC}"
        exit 1
    fi
    
    # Check Redis version
    REDIS_VERSION=$(redis-cli --version | awk '{print $2}')
    echo "Redis version: $REDIS_VERSION"
    
    # Check Redis memory usage
    echo "Redis memory usage:"
    redis-cli -a "$REDIS_PASSWORD" info memory | grep "used_memory_human"
    
    # Check client connections
    echo "Connected clients:"
    redis-cli -a "$REDIS_PASSWORD" info clients | grep "connected_clients"
    
    # Check listening addresses
    echo "Redis is listening on the following addresses:"
    netstat -tuln | grep $REDIS_PORT
}

# Setup backup script for Redis
setup_backup_script() {
    echo -e "${GREEN}Setting up automated backup script for Redis...${NC}"
    
    # Create backup directory
    mkdir -p /var/backups/redis
    
    # Create backup script
    cat > /usr/local/bin/redis_backup.sh << EOF
#!/bin/bash

# Redis backup script
BACKUP_DIR="/var/backups/redis"
TIMESTAMP=\$(date +"%Y%m%d-%H%M%S")
LOG_FILE="\${BACKUP_DIR}/backup_\${TIMESTAMP}.log"
REDIS_PASSWORD="$REDIS_PASSWORD"

# Ensure backup directory exists
mkdir -p "\${BACKUP_DIR}"

# Log start of backup
echo "Redis backup started at \$(date)" > "\${LOG_FILE}"

# Trigger Redis to save RDB file
redis-cli -a "\${REDIS_PASSWORD}" SAVE >> "\${LOG_FILE}" 2>&1

# Copy the RDB file to backup directory
cp /var/lib/redis/dump.rdb "\${BACKUP_DIR}/redis_\${TIMESTAMP}.rdb"
echo "Redis RDB backup completed at \$(date)" >> "\${LOG_FILE}"

# Remove backups older than 7 days
find "\${BACKUP_DIR}" -name "*.rdb" -type f -mtime +7 -delete
find "\${BACKUP_DIR}" -name "backup_*.log" -type f -mtime +7 -delete
EOF
    
    # Make backup script executable
    chmod +x /usr/local/bin/redis_backup.sh
    
    # Setup daily cron job for backups
    (crontab -l 2>/dev/null; echo "30 2 * * * /usr/local/bin/redis_backup.sh") | crontab -
    
    echo -e "${GREEN}Automated backup script setup completed.${NC}"
    echo "Redis backups will run daily at 2:30 AM and be stored in /var/backups/redis"
}

# Main execution
echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}=== Redis Installation and Configuration ===${NC}"
echo -e "${GREEN}===============================================${NC}"

# Check if Redis is already installed
if command -v redis-cli &> /dev/null; then
    echo -e "${YELLOW}Redis is already installed.${NC}"
    read -p "Do you want to reconfigure it? (y/n): " RECONFIGURE
    if [[ "$RECONFIGURE" =~ ^[Yy]$ ]]; then
        configure_network
        tune_redis
        setup_firewall_rules
    fi
else
    # Install and configure Redis
    install_redis
    configure_network
    tune_redis
    setup_firewall_rules
fi

# Ask if the user wants to setup automated backups
read -p "Do you want to setup automated daily backups? (y/n): " SETUP_BACKUPS
if [[ "$SETUP_BACKUPS" =~ ^[Yy]$ ]]; then
    setup_backup_script
fi

# Check final status
check_redis_status

# Save credentials to a file
echo "Redis password: $REDIS_PASSWORD" > "/root/redis_credentials.txt"
chmod 600 "/root/redis_credentials.txt"
echo -e "${YELLOW}Redis password saved to /root/redis_credentials.txt${NC}"

echo -e "${GREEN}Redis setup completed successfully.${NC}"
echo -e "${YELLOW}Remember to save your Redis password in a secure location.${NC}"