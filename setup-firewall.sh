#!/bin/bash

# Firewall Configuration Script for DNS and Mail Server
# Usage: ./setup-firewall.sh [ufw|firewalld|iptables]

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Required ports for services
WEB_PORTS=("80" "443")                              # HTTP/HTTPS
MAIL_PORTS=("25" "465" "587" "110" "995" "143" "993") # SMTP, SMTPS, Submission, POP3, POP3S, IMAP, IMAPS
DNS_PORTS=("53")                                   # DNS (TCP/UDP)
SAMBA_PORTS=("139" "445")                          # Samba NetBIOS and Microsoft-DS
SSH_PORT="22"                                      # SSH

# Function to display usage
usage() {
    echo "Usage: $0 [ufw|firewalld|iptables]"
    echo "If no argument is provided, the script will detect your firewall system."
    exit 1
}

# Detect firewall system if not specified
if [ $# -eq 0 ]; then
    if command -v ufw &> /dev/null && ufw status &> /dev/null; then
        FIREWALL="ufw"
    elif command -v firewall-cmd &> /dev/null; then
        FIREWALL="firewalld"
    elif command -v iptables &> /dev/null; then
        FIREWALL="iptables"
    else
        echo -e "${YELLOW}No firewall detected. Installing UFW...${NC}"
        apt-get update && apt-get install -y ufw
        FIREWALL="ufw"
    fi
elif [ $# -eq 1 ]; then
    FIREWALL=$1
    case $FIREWALL in
        ufw|firewalld|iptables)
            # Valid argument
            ;;
        *)
            usage
            ;;
    esac
else
    usage
fi

echo -e "${GREEN}Configuring $FIREWALL firewall for mail and web services...${NC}"

# UFW Configuration
configure_ufw() {
    echo "Setting up UFW firewall..."
    
    # Check if UFW is installed
    if ! command -v ufw &> /dev/null; then
        echo "Installing UFW..."
        apt-get update && apt-get install -y ufw
    fi
    
    # Reset UFW to default settings
    echo "Resetting UFW to defaults..."
    ufw --force reset
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH
    echo "Allowing SSH (port $SSH_PORT)..."
    ufw allow $SSH_PORT/tcp
    
    # Allow web ports
    echo "Allowing web ports..."
    for port in "${WEB_PORTS[@]}"; do
        echo "Opening port $port/tcp for web services"
        ufw allow $port/tcp
    done
    
    # Allow mail ports
    echo "Allowing mail ports..."
    for port in "${MAIL_PORTS[@]}"; do
        echo "Opening port $port/tcp for mail services"
        ufw allow $port/tcp
    done
    
    # Allow DNS ports (both TCP and UDP)
    echo "Allowing DNS ports..."
    for port in "${DNS_PORTS[@]}"; do
        echo "Opening port $port/tcp and $port/udp for DNS"
        ufw allow $port/tcp
        ufw allow $port/udp
    done
    
    # Allow Samba ports for WinRemote user
    echo "Allowing Samba ports..."
    for port in "${SAMBA_PORTS[@]}"; do
        echo "Opening port $port/tcp for Samba services"
        ufw allow $port/tcp
    done
    
    # Enable UFW
    echo "Enabling UFW..."
    ufw --force enable
    
    echo "UFW configuration complete."
    ufw status verbose
}

# FirewallD Configuration
configure_firewalld() {
    echo "Setting up FirewallD firewall..."
    
    # Check if FirewallD is installed
    if ! command -v firewall-cmd &> /dev/null; then
        echo "Installing FirewallD..."
        if command -v dnf &> /dev/null; then
            dnf install -y firewalld
        else
            apt-get update && apt-get install -y firewalld
        fi
        systemctl enable firewalld
        systemctl start firewalld
    fi
    
    # Basic setup
    echo "Configuring FirewallD services..."
    
    # Allow SSH
    echo "Allowing SSH (port $SSH_PORT)..."
    firewall-cmd --permanent --add-service=ssh
    
    # Allow web services
    echo "Allowing web services..."
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    
    # Allow mail services
    echo "Allowing mail services..."
    firewall-cmd --permanent --add-service=smtp
    firewall-cmd --permanent --add-service=smtps
    firewall-cmd --permanent --add-service=imap
    firewall-cmd --permanent --add-service=imaps
    firewall-cmd --permanent --add-service=pop3
    firewall-cmd --permanent --add-service=pop3s
    
    # Add submission port (587) which might not be in a predefined service
    firewall-cmd --permanent --add-port=587/tcp
    
    # Allow DNS service
    echo "Allowing DNS service..."
    firewall-cmd --permanent --add-service=dns
    
    # Allow Samba services for WinRemote user
    echo "Allowing Samba services..."
    firewall-cmd --permanent --add-service=samba
    
    # Reload to apply changes
    firewall-cmd --reload
    
    echo "FirewallD configuration complete."
    firewall-cmd --list-all
}

# IPTables Configuration
configure_iptables() {
    echo "Setting up iptables firewall..."
    
    # Check if iptables-persistent is installed
    if ! command -v iptables-save &> /dev/null; then
        echo "Installing iptables-persistent..."
        apt-get update
        # Automatically accept the prompt during installation
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        apt-get install -y iptables-persistent
    fi
    
    # Flush existing rules
    iptables -F
    
    # Set default policies
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # Allow established connections
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    
    # Allow SSH
    echo "Allowing SSH (port $SSH_PORT)..."
    iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
    
    # Allow web ports
    echo "Allowing web ports..."
    for port in "${WEB_PORTS[@]}"; do
        echo "Opening port $port/tcp for web services"
        iptables -A INPUT -p tcp --dport $port -j ACCEPT
    done
    
    # Allow mail ports
    echo "Allowing mail ports..."
    for port in "${MAIL_PORTS[@]}"; do
        echo "Opening port $port/tcp for mail services"
        iptables -A INPUT -p tcp --dport $port -j ACCEPT
    done
    
    # Allow DNS ports (both TCP and UDP)
    echo "Allowing DNS ports..."
    for port in "${DNS_PORTS[@]}"; do
        echo "Opening port $port/tcp and $port/udp for DNS"
        iptables -A INPUT -p tcp --dport $port -j ACCEPT
        iptables -A INPUT -p udp --dport $port -j ACCEPT
    done
    
    # Allow Samba ports for WinRemote user
    echo "Allowing Samba ports..."
    for port in "${SAMBA_PORTS[@]}"; do
        echo "Opening port $port/tcp for Samba services"
        iptables -A INPUT -p tcp --dport $port -j ACCEPT
    done
    
    # Save rules
    echo "Saving iptables rules..."
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    
    # Configure IPv6 too
    ip6tables -F
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -i lo -j ACCEPT
    
    # IPv6 services (same as IPv4)
    ip6tables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
    
    for port in "${WEB_PORTS[@]}"; do
        ip6tables -A INPUT -p tcp --dport $port -j ACCEPT
    done
    
    for port in "${MAIL_PORTS[@]}"; do
        ip6tables -A INPUT -p tcp --dport $port -j ACCEPT
    done
    
    for port in "${DNS_PORTS[@]}"; do
        ip6tables -A INPUT -p tcp --dport $port -j ACCEPT
        ip6tables -A INPUT -p udp --dport $port -j ACCEPT
    done
    
    for port in "${SAMBA_PORTS[@]}"; do
        ip6tables -A INPUT -p tcp --dport $port -j ACCEPT
    done
    
    # Save IPv6 rules
    ip6tables-save > /etc/iptables/rules.v6
    
    echo "iptables configuration complete."
    iptables -L -v
}

# Configure the selected firewall
case $FIREWALL in
    ufw)
        configure_ufw
        ;;
    firewalld)
        configure_firewalld
        ;;
    iptables)
        configure_iptables
        ;;
    *)
        echo "Unsupported firewall type: $FIREWALL"
        exit 1
        ;;
esac

# Install fail2ban for additional security
echo -e "\n${GREEN}Setting up fail2ban for additional security...${NC}"
if ! command -v fail2ban-client &> /dev/null; then
    apt-get update && apt-get install -y fail2ban
    systemctl enable fail2ban
    systemctl start fail2ban
    
    # Basic fail2ban configuration for SSH, mail and web services
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = $SSH_PORT
logpath = %(sshd_log)s
banaction = %(banaction_allports)s

[postfix]
enabled = true
port = 25,465,587
logpath = %(postfix_log)s
banaction = %(banaction_allports)s

[dovecot]
enabled = true
port = 110,995,143,993
logpath = %(dovecot_log)s
banaction = %(banaction_allports)s

[apache]
enabled = true
port = 80,443
logpath = %(apache_access_log)s
banaction = %(banaction_allports)s

[nginx-http-auth]
enabled = true
port = 80,443
logpath = %(nginx_error_log)s
banaction = %(banaction_allports)s
EOF
    
    # Restart fail2ban to apply new config
    systemctl restart fail2ban
    
    echo "fail2ban configured and started."
else
    echo "fail2ban is already installed."
fi

echo -e "\n${GREEN}Firewall and security configuration complete!${NC}"
echo -e "Remember to run the firewall check script to verify everything is working correctly."
echo -e "Samba services have been enabled for the WinRemote user."
