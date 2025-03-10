#!/bin/bash

# Firewall Configuration Check Script
# Usage: ./check-firewall.sh

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Required ports for DNS, mail, and web services
WEB_PORTS=("80" "443")
MAIL_PORTS=("25" "465" "587" "110" "995" "143" "993")
DNS_PORTS=("53")

# IPv4 addresses from our setup
IPV4_MAIN="136.243.2.232"
IPV4_MAIL="136.243.2.234"

# IPv6 subnet
IPV6_PREFIX="2a01:4f8:211:1c4b"

echo "========== Firewall Configuration Check =========="
echo "Checking which firewall system is active..."

# Firewall detection
FIREWALL_TYPE=""
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    FIREWALL_TYPE="ufw"
    echo -e "${GREEN}UFW is active${NC}"
elif command -v firewalld &> /dev/null && firewall-cmd --state | grep -q "running"; then
    FIREWALL_TYPE="firewalld"
    echo -e "${GREEN}FirewallD is active${NC}"
elif iptables -L | grep -q "Chain"; then
    FIREWALL_TYPE="iptables"
    echo -e "${GREEN}iptables is active${NC}"
else
    echo -e "${RED}No active firewall detected! This is a security risk.${NC}"
    echo "Installing and configuring UFW..."
    apt-get update && apt-get install -y ufw
    FIREWALL_TYPE="ufw"
fi

# Determine server's public IP addresses
echo "Detecting server IP addresses..."
SERVER_IPV4=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
SERVER_IPV6=$(ip -6 addr show | grep -oP '(?<=inet6\s)[\da-f:]+' | grep -v "::1" | grep -v "fe80" | head -n 1)

echo "Server IPv4: $SERVER_IPV4"
echo "Server IPv6: $SERVER_IPV6"

echo "Checking if server IP matches DNS setup..."
if [[ "$SERVER_IPV4" == "$IPV4_MAIN" ]] || [[ "$SERVER_IPV4" == "$IPV4_MAIL" ]]; then
    echo -e "${GREEN}Server IPv4 matches DNS configuration${NC}"
else
    echo -e "${YELLOW}Warning: Server IPv4 ($SERVER_IPV4) doesn't match DNS configuration ($IPV4_MAIN/$IPV4_MAIL)${NC}"
    echo "You may need to update your DNS records or server configuration."
fi

if [[ "$SERVER_IPV6" == $IPV6_PREFIX* ]]; then
    echo -e "${GREEN}Server IPv6 matches DNS configuration${NC}"
else
    echo -e "${YELLOW}Warning: Server IPv6 ($SERVER_IPV6) doesn't match DNS configuration prefix ($IPV6_PREFIX)${NC}"
    echo "You may need to update your DNS records or server configuration."
fi

# Check required ports
echo -e "\n========== Port Configuration Check =========="

check_port_ufw() {
    local port=$1
    local service=$2
    
    if ufw status | grep -E "$port/(tcp|udp)" | grep -q "ALLOW"; then
        echo -e "${GREEN}Port $port ($service): Open${NC}"
        return 0
    else
        echo -e "${RED}Port $port ($service): Closed${NC}"
        return 1
    }
}

check_port_firewalld() {
    local port=$1
    local service=$2
    
    if firewall-cmd --list-ports | grep -q "$port/tcp"; then
        echo -e "${GREEN}Port $port ($service): Open${NC}"
        return 0
    else
        echo -e "${RED}Port $port ($service): Closed${NC}"
        return 1
    }
}

check_port_iptables() {
    local port=$1
    local service=$2
    
    if iptables -L INPUT -nv | grep -q "dpt:$port"; then
        echo -e "${GREEN}Port $port ($service): Open${NC}"
        return 0
    else
        echo -e "${RED}Port $port ($service): Closed${NC}"
        return 1
    }
}

# Use the appropriate firewall check function
check_port() {
    local port=$1
    local service=$2
    
    case $FIREWALL_TYPE in
        ufw)
            check_port_ufw "$port" "$service"
            ;;
        firewalld)
            check_port_firewalld "$port" "$service"
            ;;
        iptables)
            check_port_iptables "$port" "$service"
            ;;
    esac
    
    return $?
}

# Check web server ports
echo "Checking web server ports..."
for port in "${WEB_PORTS[@]}"; do
    if [[ $port == "80" ]]; then
        check_port "$port" "HTTP"
    else
        check_port "$port" "HTTPS"
    fi
done

# Check mail server ports
echo -e "\nChecking mail server ports..."
for port in "${MAIL_PORTS[@]}"; do
    case $port in
        25)
            check_port "$port" "SMTP"
            ;;
        465)
            check_port "$port" "SMTPS"
            ;;
        587)
            check_port "$port" "Submission"
            ;;
        110)
            check_port "$port" "POP3"
            ;;
        995)
            check_port "$port" "POP3S"
            ;;
        143)
            check_port "$port" "IMAP"
            ;;
        993)
            check_port "$port" "IMAPS"
            ;;
    esac
done

# Check DNS ports
echo -e "\nChecking DNS ports..."
for port in "${DNS_PORTS[@]}"; do
    check_port "$port" "DNS" 
done

# Generate firewall configuration recommendations
echo -e "\n========== Firewall Configuration Recommendations =========="

missing_ports=()

# Check all ports and add missing ones to the list
for port in "${WEB_PORTS[@]}" "${MAIL_PORTS[@]}" "${DNS_PORTS[@]}"; do
    if ! check_port "$port" "" > /dev/null; then
        missing_ports+=("$port")
    fi
done

if [ ${#missing_ports[@]} -eq 0 ]; then
    echo -e "${GREEN}All required ports are open.${NC}"
else
    echo -e "${YELLOW}The following ports need to be opened:${NC}"
    
    case $FIREWALL_TYPE in
        ufw)
            echo -e "\n${YELLOW}UFW commands to fix configuration:${NC}"
            for port in "${missing_ports[@]}"; do
                echo "sudo ufw allow $port/tcp"
            done
            echo "sudo ufw reload"
            ;;
        firewalld)
            echo -e "\n${YELLOW}FirewallD commands to fix configuration:${NC}"
            for port in "${missing_ports[@]}"; do
                echo "sudo firewall-cmd --permanent --add-port=$port/tcp"
            done
            echo "sudo firewall-cmd --reload"
            ;;
        iptables)
            echo -e "\n${YELLOW}iptables commands to fix configuration:${NC}"
            for port in "${missing_ports[@]}"; do
                echo "sudo iptables -A INPUT -p tcp --dport $port -j ACCEPT"
            done
            echo "sudo iptables-save > /etc/iptables/rules.v4"
            ;;
    esac
fi

# Service Check
echo -e "\n========== Service Configuration Check =========="

check_service() {
    local service=$1
    local description=$2
    
    if systemctl is-active --quiet "$service"; then
        echo -e "${GREEN}$description (${service}): Running${NC}"
    else
        echo -e "${RED}$description (${service}): Not running${NC}"
    fi
}

# Check common web and mail services
check_service "nginx" "Web Server"
check_service "apache2" "Web Server"
check_service "postfix" "Mail Server"
check_service "dovecot" "IMAP/POP3 Server"
check_service "opendkim" "DKIM Service"
check_service "opendmarc" "DMARC Service"
check_service "spamassassin" "Spam Filter"
check_service "bind9" "DNS Server"

echo -e "\n========== Recommendations Summary =========="
echo "1. Make sure your firewall is properly configured"
echo "2. Ensure all required services are running"
echo "3. Verify that your server IPs match your DNS configuration"
echo "4. Consider setting up fail2ban for additional security"
echo "5. Check that mail server is properly configured to use DKIM/SPF"

# Offer to fix configuration
if [ ${#missing_ports[@]} -gt 0 ]; then
    echo -e "\nWould you like to automatically fix the firewall configuration? (y/n)"
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        case $FIREWALL_TYPE in
            ufw)
                echo "Opening missing ports in UFW..."
                for port in "${missing_ports[@]}"; do
                    ufw allow "$port"/tcp
                done
                ufw reload
                ;;
            firewalld)
                echo "Opening missing ports in FirewallD..."
                for port in "${missing_ports[@]}"; do
                    firewall-cmd --permanent --add-port="$port"/tcp
                done
                firewall-cmd --reload
                ;;
            iptables)
                echo "Opening missing ports in iptables..."
                for port in "${missing_ports[@]}"; do
                    iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
                done
                # Check if iptables-persistent is installed
                if command -v iptables-save &> /dev/null; then
                    iptables-save > /etc/iptables/rules.v4
                else
                    echo "Installing iptables-persistent to save rules..."
                    apt-get update && apt-get install -y iptables-persistent
                    iptables-save > /etc/iptables/rules.v4
                fi
                ;;
        esac
        echo -e "${GREEN}Firewall configuration updated.${NC}"
    fi
fi

echo -e "\nCheck complete. Please review the findings above."