#!/bin/bash

# PostgreSQL Installation and Configuration Script
# Usage: ./setup-postgres.sh [password]

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Configuration variables
PG_VERSION="14"  # PostgreSQL version - change as needed
PG_USER="postgres"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/main"
PG_CONFIG_DIR="/etc/postgresql/${PG_VERSION}/main"
PG_LISTEN_ADDRESSES="localhost,136.243.2.232"  # Comma-separated list of addresses to listen on
EXTERNAL_IP="136.243.2.232"

# Check if password is provided or generate one
if [ $# -eq 1 ]; then
    PG_PASSWORD=$1
else
    # Generate a secure random password
    PG_PASSWORD=$(openssl rand -base64 16)
    echo -e "${YELLOW}No password provided. Generated password: ${PG_PASSWORD}${NC}"
    echo "Save this password in a secure location!"
fi

# Function to install PostgreSQL
install_postgres() {
    echo -e "${GREEN}Installing PostgreSQL ${PG_VERSION}...${NC}"
    
    # Add PostgreSQL repository
    if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
        echo "Adding PostgreSQL repository..."
        echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
        wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
    fi
    
    # Update package lists and install PostgreSQL
    apt-get update
    apt-get install -y "postgresql-${PG_VERSION}" "postgresql-contrib-${PG_VERSION}"
    
    # Verify installation
    if systemctl is-active --quiet postgresql; then
        echo -e "${GREEN}PostgreSQL ${PG_VERSION} installed successfully.${NC}"
    else
        echo -e "${RED}PostgreSQL installation failed.${NC}"
        exit 1
    fi
}

# Function to configure PostgreSQL networking
configure_network() {
    echo -e "${GREEN}Configuring PostgreSQL network settings...${NC}"
    
    # Stop PostgreSQL service
    systemctl stop postgresql
    
    # Backup original postgresql.conf
    cp "${PG_CONFIG_DIR}/postgresql.conf" "${PG_CONFIG_DIR}/postgresql.conf.bak"
    
    # Update listen_addresses in postgresql.conf
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '${PG_LISTEN_ADDRESSES}'/" "${PG_CONFIG_DIR}/postgresql.conf"
    
    # Backup original pg_hba.conf
    cp "${PG_CONFIG_DIR}/pg_hba.conf" "${PG_CONFIG_DIR}/pg_hba.conf.bak"
    
    # Update pg_hba.conf to allow connections from the specified IP
    echo "# Allow connections from the specified external IP" >> "${PG_CONFIG_DIR}/pg_hba.conf"
    echo "host    all             all             ${EXTERNAL_IP}/32           md5" >> "${PG_CONFIG_DIR}/pg_hba.conf"
    
    # Start PostgreSQL service
    systemctl start postgresql
    
    echo -e "${GREEN}PostgreSQL network configuration updated.${NC}"
}

# Function to set PostgreSQL password
set_postgres_password() {
    echo -e "${GREEN}Setting PostgreSQL password...${NC}"
    
    # Set PostgreSQL password
    su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD '${PG_PASSWORD}';\""
    
    echo -e "${GREEN}PostgreSQL password set successfully.${NC}"
}

# Function to create a basic database and user
setup_initial_database() {
    echo -e "${GREEN}Setting up initial database...${NC}"
    
    # Prompt for database name and user
    read -p "Enter a name for the initial database (default: appdb): " DB_NAME
    DB_NAME=${DB_NAME:-appdb}
    
    read -p "Enter a name for the database user (default: appuser): " DB_USER
    DB_USER=${DB_USER:-appuser}
    
    # Generate a password for the database user
    DB_PASSWORD=$(openssl rand -base64 16)
    
    # Create database and user
    su - postgres -c "psql -c \"CREATE DATABASE ${DB_NAME};\""
    su - postgres -c "psql -c \"CREATE USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASSWORD}';\""
    su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};\""
    
    echo -e "${GREEN}Database '${DB_NAME}' and user '${DB_USER}' created successfully.${NC}"
    echo -e "${YELLOW}User credentials:${NC}"
    echo "Database: ${DB_NAME}"
    echo "Username: ${DB_USER}"
    echo "Password: ${DB_PASSWORD}"
    echo "Save these credentials in a secure location!"
    
    # Save credentials to a file
    echo "Database: ${DB_NAME}" > "/root/postgres_credentials.txt"
    echo "Username: ${DB_USER}" >> "/root/postgres_credentials.txt"
    echo "Password: ${DB_PASSWORD}" >> "/root/postgres_credentials.txt"
    echo "PostgreSQL admin password: ${PG_PASSWORD}" >> "/root/postgres_credentials.txt"
    chmod 600 "/root/postgres_credentials.txt"
    
    echo -e "${YELLOW}Credentials saved to /root/postgres_credentials.txt${NC}"
}

# Function to configure PostgreSQL for performance
tune_postgresql() {
    echo -e "${GREEN}Tuning PostgreSQL performance...${NC}"
    
    # Get system memory
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
    
    # Calculate shared_buffers (25% of system memory)
    SHARED_BUFFERS=$((TOTAL_MEM_MB / 4))
    
    # Calculate effective_cache_size (75% of system memory)
    EFFECTIVE_CACHE_SIZE=$((TOTAL_MEM_MB * 3 / 4))
    
    # Calculate work_mem (4% of system memory, but not more than 1GB)
    WORK_MEM=$((TOTAL_MEM_MB * 4 / 100))
    if [ $WORK_MEM -gt 1024 ]; then
        WORK_MEM=1024
    fi
    
    # Update postgresql.conf with performance settings
    cat >> "${PG_CONFIG_DIR}/postgresql.conf" << EOF

# Added performance tuning parameters
shared_buffers = ${SHARED_BUFFERS}MB
effective_cache_size = ${EFFECTIVE_CACHE_SIZE}MB
work_mem = ${WORK_MEM}MB
maintenance_work_mem = ${WORK_MEM}MB
max_connections = 100
max_worker_processes = 8
max_parallel_workers_per_gather = 4
max_parallel_workers = 8
random_page_cost = 1.1
EOF
    
    # Restart PostgreSQL to apply changes
    systemctl restart postgresql
    
    echo -e "${GREEN}PostgreSQL performance tuning completed.${NC}"
}

# Function to setup firewall rules for PostgreSQL
setup_firewall_rules() {
    echo -e "${GREEN}Setting up firewall rules for PostgreSQL...${NC}"
    
    # Check which firewall is in use
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        echo "Configuring UFW firewall..."
        # Allow PostgreSQL connections from localhost
        ufw allow from 127.0.0.1 to any port 5432
        # Allow PostgreSQL connections from the specific external IP
        ufw allow from ${EXTERNAL_IP} to any port 5432
        
    elif command -v firewall-cmd &> /dev/null && firewall-cmd --state | grep -q "running"; then
        echo "Configuring FirewallD firewall..."
        # Allow PostgreSQL connections
        firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"127.0.0.1\" port protocol=\"tcp\" port=\"5432\" accept"
        firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"${EXTERNAL_IP}\" port protocol=\"tcp\" port=\"5432\" accept"
        firewall-cmd --reload
        
    elif command -v iptables &> /dev/null; then
        echo "Configuring iptables firewall..."
        # Allow PostgreSQL connections from localhost
        iptables -A INPUT -p tcp -s 127.0.0.1 --dport 5432 -j ACCEPT
        # Allow PostgreSQL connections from the specific external IP
        iptables -A INPUT -p tcp -s ${EXTERNAL_IP} --dport 5432 -j ACCEPT
        
        # Save iptables rules
        if command -v iptables-save &> /dev/null; then
            iptables-save > /etc/iptables/rules.v4
        fi
    else
        echo -e "${YELLOW}No active firewall detected. Consider setting up a firewall.${NC}"
    fi
    
    echo -e "${GREEN}Firewall rules for PostgreSQL configured.${NC}"
}

# Function to check PostgreSQL status
check_postgres_status() {
    echo -e "${GREEN}Checking PostgreSQL status...${NC}"
    
    # Check if PostgreSQL is running
    if systemctl is-active --quiet postgresql; then
        echo -e "${GREEN}PostgreSQL is running.${NC}"
    else
        echo -e "${RED}PostgreSQL is not running.${NC}"
        exit 1
    fi
    
    # Check PostgreSQL version
    PG_ACTUAL_VERSION=$(su - postgres -c "psql -c 'SELECT version();'" | grep PostgreSQL | awk '{print $2}')
    echo "PostgreSQL version: ${PG_ACTUAL_VERSION}"
    
    # Check listening addresses
    echo "PostgreSQL is listening on the following addresses:"
    netstat -tuln | grep 5432
    
    # Check database sizes
    echo "Database sizes:"
    su - postgres -c "psql -c 'SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname) DESC;'"
}

# Setup backup script
setup_backup_script() {
    echo -e "${GREEN}Setting up automated backup script...${NC}"
    
    # Create backup directory
    mkdir -p /var/backups/postgresql
    
    # Create backup script
    cat > /usr/local/bin/pg_backup.sh << 'EOF'
#!/bin/bash

# PostgreSQL backup script
BACKUP_DIR="/var/backups/postgresql"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="${BACKUP_DIR}/backup_${TIMESTAMP}.log"

# Ensure backup directory exists
mkdir -p "${BACKUP_DIR}"

# Get list of all databases
DATABASES=$(su - postgres -c "psql -t -c 'SELECT datname FROM pg_database WHERE datname NOT IN (\"template0\", \"template1\", \"postgres\")'")

# Log start of backup
echo "PostgreSQL backup started at $(date)" > "${LOG_FILE}"

# Backup each database
for DB in $DATABASES; do
    echo "Backing up database: ${DB}" >> "${LOG_FILE}"
    BACKUP_FILE="${BACKUP_DIR}/${DB}_${TIMESTAMP}.sql.gz"
    if su - postgres -c "pg_dump ${DB} | gzip > ${BACKUP_FILE}"; then
        echo "Backup of ${DB} completed successfully." >> "${LOG_FILE}"
    else
        echo "Backup of ${DB} failed!" >> "${LOG_FILE}"
    fi
done

# Log end of backup
echo "PostgreSQL backup completed at $(date)" >> "${LOG_FILE}"

# Remove backups older than 7 days
find "${BACKUP_DIR}" -name "*.sql.gz" -type f -mtime +7 -delete
find "${BACKUP_DIR}" -name "backup_*.log" -type f -mtime +7 -delete
EOF
    
    # Make backup script executable
    chmod +x /usr/local/bin/pg_backup.sh
    
    # Setup daily cron job for backups
    (crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/pg_backup.sh") | crontab -
    
    echo -e "${GREEN}Automated backup script setup completed.${NC}"
    echo "Backups will run daily at 2:00 AM and be stored in /var/backups/postgresql"
}

# Main execution
echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}=== PostgreSQL Installation and Configuration ===${NC}"
echo -e "${GREEN}===============================================${NC}"

# Check if PostgreSQL is already installed
if command -v psql &> /dev/null; then
    echo -e "${YELLOW}PostgreSQL is already installed.${NC}"
    read -p "Do you want to reconfigure it? (y/n): " RECONFIGURE
    if [[ "$RECONFIGURE" =~ ^[Yy]$ ]]; then
        configure_network
        set_postgres_password
        tune_postgresql
        setup_firewall_rules
    fi
else
    # Install and configure PostgreSQL
    install_postgres
    configure_network
    set_postgres_password
    tune_postgresql
    setup_firewall_rules
fi

# Ask if the user wants to create an initial database
read -p "Do you want to create an initial database and user? (y/n): " CREATE_DB
if [[ "$CREATE_DB" =~ ^[Yy]$ ]]; then
    setup_initial_database
fi

# Ask if the user wants to setup automated backups
read -p "Do you want to setup automated daily backups? (y/n): " SETUP_BACKUPS
if [[ "$SETUP_BACKUPS" =~ ^[Yy]$ ]]; then
    setup_backup_script
fi

# Check final status
check_postgres_status

echo -e "${GREEN}PostgreSQL setup completed successfully.${NC}"
echo -e "${YELLOW}Remember to save your PostgreSQL credentials in a secure location.${NC}"