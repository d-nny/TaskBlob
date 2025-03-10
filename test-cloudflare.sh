#!/bin/bash
# Test Cloudflare API connection directly

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Load environment variables from .env file
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
  echo -e "${GREEN}Loaded environment variables from .env file${NC}"
fi

# Display credentials being used
echo -e "${GREEN}Using the following Cloudflare credentials:${NC}"
echo -e "  Email: ${CLOUDFLARE_EMAIL}"
echo -e "  API Key: ${CLOUDFLARE_API_KEY:0:5}... (partially hidden for security)"
echo -e "  Domain: ${DOMAIN}"

# Check if domain zone exists in Cloudflare
echo -e "\n${GREEN}Checking if zone for domain ${DOMAIN} exists in Cloudflare...${NC}"
ZONE_CHECK=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" \
     -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
     -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
     -H "Content-Type: application/json")

echo "Raw response: $ZONE_CHECK"

if [[ "$ZONE_CHECK" == *'"result":[]'* ]]; then
    echo -e "${RED}Zone for domain ${DOMAIN} does not exist in Cloudflare!${NC}"
    echo -e "${YELLOW}You need to add this domain to your Cloudflare account first.${NC}"
    
    echo -e "\n${GREEN}Would you like to create the zone now? (y/N)${NC}"
    read -p "Create zone? " create_zone
    
    if [[ "$create_zone" == "y" || "$create_zone" == "Y" ]]; then
        echo -e "${GREEN}Attempting to create zone for ${DOMAIN}...${NC}"
        ZONE_CREATE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones" \
             -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
             -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
             -H "Content-Type: application/json" \
             --data "{\"name\":\"${DOMAIN}\",\"jump_start\":true}")
        
        echo "Zone creation response: $ZONE_CREATE"
        
        if [[ "$ZONE_CREATE" == *'"success":true'* ]]; then
            echo -e "${GREEN}Zone created successfully!${NC}"
            echo -e "${YELLOW}IMPORTANT: You must update your domain's nameservers to point to Cloudflare.${NC}"
            echo -e "Please log in to your Cloudflare account to see the required nameservers."
        else
            echo -e "${RED}Failed to create zone.${NC}"
            echo -e "Error details: $ZONE_CREATE"
        fi
    else
        echo -e "${YELLOW}Zone creation skipped. Please add the domain to Cloudflare manually.${NC}"
    fi
elif [[ "$ZONE_CHECK" == *'"success":true'* ]]; then
    echo -e "${GREEN}Zone for domain ${DOMAIN} exists in Cloudflare!${NC}"
    ZONE_ID=$(echo $ZONE_CHECK | grep -o '"id":"[^"]*' | cut -d'"' -f4)
    echo -e "Zone ID: ${ZONE_ID}"
    
    # Check if we can list DNS records for this zone
    echo -e "\n${GREEN}Checking if we can list DNS records for this zone...${NC}"
    DNS_LIST=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
         -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
         -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
         -H "Content-Type: application/json")
    
    if [[ "$DNS_LIST" == *'"success":true'* ]]; then
        echo -e "${GREEN}Successfully listed DNS records!${NC}"
        RECORD_COUNT=$(echo $DNS_LIST | grep -o '"count":[0-9]*' | cut -d':' -f2)
        echo -e "Found ${RECORD_COUNT} DNS records in this zone."
    else
        echo -e "${RED}Failed to list DNS records.${NC}"
        echo -e "Error details: $DNS_LIST"
    fi
else
    echo -e "${RED}Error checking zone:${NC}"
    echo -e "Error details: $ZONE_CHECK"
fi

echo -e "\n${GREEN}Cloudflare API test complete!${NC}"
