#!/bin/bash

# DKIM Key Generation Script
# Usage: ./generate-dkim.sh domain.com

# Configuration
DKIM_DIR="/var/server/dkim"
SELECTOR="mail" # Common selector name

# Check if OpenDKIM is installed
if ! command -v opendkim-genkey &> /dev/null; then
    echo "OpenDKIM tools not found. Installing..."
    apt-get update && apt-get install -y opendkim opendkim-tools
fi

# Check if domain is provided
if [ $# -lt 1 ]; then
    echo "Usage: $0 domain.com"
    exit 1
fi

DOMAIN=$1
DOMAIN_DIR="${DKIM_DIR}/${DOMAIN}"

# Create directory for domain if it doesn't exist
if [ ! -d "${DOMAIN_DIR}" ]; then
    echo "Creating DKIM directory for ${DOMAIN}..."
    mkdir -p "${DOMAIN_DIR}"
fi

# Generate DKIM keys
echo "Generating DKIM keys for ${DOMAIN}..."
cd "${DOMAIN_DIR}"
opendkim-genkey -b 2048 -d "${DOMAIN}" -s "${SELECTOR}" -v

# Set proper permissions
chmod 644 "${SELECTOR}.txt"
chmod 600 "${SELECTOR}.private"

# Get the DKIM TXT record
DKIM_RECORD=$(cat "${SELECTOR}.txt" | grep -o "v=DKIM1.*" | tr -d '"' | tr -d ' ')

echo "===== DKIM Setup Complete for ${DOMAIN} ====="
echo "Private key location: ${DOMAIN_DIR}/${SELECTOR}.private"
echo 
echo "Add this record to your DNS:"
echo "Name: ${SELECTOR}._domainkey.${DOMAIN}"
echo "Type: TXT"
echo "Value: ${DKIM_RECORD}"
echo
echo "For OpenDKIM configuration, add the following to your KeyTable:"
echo "${SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${SELECTOR}:${DOMAIN_DIR}/${SELECTOR}.private"
echo
echo "And to your SigningTable:"
echo "*@${DOMAIN} ${SELECTOR}._domainkey.${DOMAIN}"

# Return the DKIM record for use in DNSupdate script
echo "${DKIM_RECORD}" > "${DOMAIN_DIR}/dkim_record.txt"