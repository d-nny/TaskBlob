#!/bin/bash

# SSHFS Server Setup Script for Windows Client Access
# This script creates a dedicated SSHFS user and configures SSH for SSHFS access
# Usage: ./setup-sshfs.sh [username] [directory_to_share]

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# Default values
DEFAULT_USER="sshfs_user"
DEFAULT_DIR="/var/server"
SERVER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)

# Process arguments
SSHFS_USER=${1:-$DEFAULT_USER}
SHARE_DIR=${2:-$DEFAULT_DIR}

echo -e "${GREEN}========== SSHFS Server Setup for Windows Clients ==========${NC}"
echo "This script will:"
echo "1. Create a dedicated user ($SSHFS_USER) for SSHFS access"
echo "2. Configure permissions for the shared directory"
echo "3. Configure SSH server for SSHFS connections"
echo "4. Provide instructions for Windows client setup"
echo ""

# Install required packages
echo -e "${GREEN}Installing required packages...${NC}"
apt-get update
apt-get install -y openssh-server

# Create SSHFS user if it doesn't exist
if id "$SSHFS_USER" &>/dev/null; then
    echo -e "${YELLOW}User $SSHFS_USER already exists.${NC}"
else
    echo -e "${GREEN}Creating user $SSHFS_USER...${NC}"
    useradd -m -s /bin/bash "$SSHFS_USER"
    
    # Generate a secure password
    SSHFS_PASSWORD=$(openssl rand -base64 12)
    echo "$SSHFS_USER:$SSHFS_PASSWORD" | chpasswd
    
    echo -e "${YELLOW}Created user $SSHFS_USER with password: $SSHFS_PASSWORD${NC}"
    echo "SSHFS User: $SSHFS_USER" > /root/sshfs_credentials.txt
    echo "Password: $SSHFS_PASSWORD" >> /root/sshfs_credentials.txt
    chmod 600 /root/sshfs_credentials.txt
fi

# Configure permissions for the shared directory
echo -e "${GREEN}Configuring permissions for $SHARE_DIR...${NC}"
if [ ! -d "$SHARE_DIR" ]; then
    echo -e "${YELLOW}Directory $SHARE_DIR does not exist. Creating it...${NC}"
    mkdir -p "$SHARE_DIR"
fi

# Set appropriate permissions
# We'll create a group for SSHFS access and add the SSHFS user to it
groupadd -f sshfs_access
usermod -a -G sshfs_access "$SSHFS_USER"

# Set directory ownership and permissions
chown root:sshfs_access "$SHARE_DIR"
chmod 750 "$SHARE_DIR"
# Allow read access to the directory contents
find "$SHARE_DIR" -type d -exec chmod g+rx {} \;
find "$SHARE_DIR" -type f -exec chmod g+r {} \;

# For /var/server specifically, setup finer-grained permissions
if [ "$SHARE_DIR" == "/var/server" ]; then
    echo -e "${GREEN}Setting up specific permissions for /var/server...${NC}"
    
    # Ensure read access to all subdirectories
    find /var/server -type d -exec chmod g+rx {} \;
    # Ensure read access to most files
    find /var/server -type f -exec chmod g+r {} \;
    
    # Protect sensitive files
    if [ -d "/var/server/dns" ]; then
        chmod 750 /var/server/dns
        if [ -f "/var/server/dns/cloudflare_api_key.txt" ]; then
            chmod 640 /var/server/dns/cloudflare_api_key.txt
        fi
        if [ -f "/var/server/dns/cloudflare_email.txt" ]; then
            chmod 640 /var/server/dns/cloudflare_email.txt
        fi
    fi
    
    # Protect SSL keys
    find /var/server -name "*.key" -o -name "*.pem" -o -name "*.private" -exec chmod 640 {} \;
fi

# Configure SSH server for SSHFS
echo -e "${GREEN}Configuring SSH server for SSHFS...${NC}"
if ! grep -q "^Subsystem sftp" /etc/ssh/sshd_config; then
    echo "Adding SFTP subsystem configuration..."
    echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> /etc/ssh/sshd_config
fi

# Restart SSH service to apply changes
systemctl restart ssh

# Create SSH key for password-less authentication (optional)
echo -e "${GREEN}Creating SSH key for optional password-less authentication...${NC}"
if [ ! -d "/home/$SSHFS_USER/.ssh" ]; then
    mkdir -p "/home/$SSHFS_USER/.ssh"
    chmod 700 "/home/$SSHFS_USER/.ssh"
    touch "/home/$SSHFS_USER/.ssh/authorized_keys"
    chmod 600 "/home/$SSHFS_USER/.ssh/authorized_keys"
    chown -R "$SSHFS_USER:$SSHFS_USER" "/home/$SSHFS_USER/.ssh"
fi

# Generate SSH key pair for Windows client
ssh-keygen -t rsa -b 4096 -f /tmp/sshfs_key -N ""
cat /tmp/sshfs_key.pub >> "/home/$SSHFS_USER/.ssh/authorized_keys"
chown "$SSHFS_USER:$SSHFS_USER" "/home/$SSHFS_USER/.ssh/authorized_keys"

# Open SSH port in firewall if necessary
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    echo "Ensuring SSH port is open in UFW firewall..."
    ufw allow ssh
elif command -v firewall-cmd &> /dev/null && firewall-cmd --state | grep -q "running"; then
    echo "Ensuring SSH port is open in FirewallD firewall..."
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --reload
elif command -v iptables &> /dev/null; then
    echo "Ensuring SSH port is open in iptables firewall..."
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    if command -v iptables-save &> /dev/null; then
        iptables-save > /etc/iptables/rules.v4
    fi
fi

# Display client configuration instructions
echo -e "\n${GREEN}========== Windows Client Setup Instructions ==========${NC}"
echo "To connect from your Windows machine, follow these steps:"
echo ""
echo "1. Install the following on your Windows machine:"
echo "   - WinFSP: https://github.com/winfsp/winfsp/releases"
echo "   - SSHFS-Win: https://github.com/winfsp/sshfs-win/releases"
echo ""
echo "2. After installation, you can use the following command to map a network drive:"
echo "   net use X: \\\\sshfs\\${SSHFS_USER}@${SERVER_IP}"
echo ""
echo "3. When prompted, enter the password: ${SSHFS_PASSWORD}"
echo ""
echo "4. Alternatively, for passwordless authentication using the generated key:"
echo "   a. Download the private key from the server to your Windows machine:"
echo "      Location on server: /tmp/sshfs_key"
echo "   b. Use the key with a command like:"
echo "      net use X: \\\\sshfs\\${SSHFS_USER}@${SERVER_IP}?idfile=C:\\path\\to\\sshfs_key"
echo ""
echo "5. To specify a subdirectory of ${SHARE_DIR}, use:"
echo "   net use X: \\\\sshfs\\${SSHFS_USER}@${SERVER_IP}!${SHARE_DIR}"
echo ""
echo "6. To disconnect the drive later:"
echo "   net use X: /delete"
echo ""
echo -e "${YELLOW}For security, save the generated key and delete it from /tmp:${NC}"
echo "The private key is at: /tmp/sshfs_key"
echo "The credentials are saved at: /root/sshfs_credentials.txt"
echo ""
echo -e "${GREEN}SSHFS server setup completed successfully.${NC}"
