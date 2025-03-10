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
    # Extract ONLY the zone ID (first occurrence)
    ZONE_ID=$(echo $ZONE_CHECK | grep -o '"id":"[^"]*' | head -n 1 | cut -d'"' -f4)
    echo -e "Zone ID: ${ZONE_ID}"
    
    # Check if we can list DNS records for this zone (with more verbose output)
    echo -e "\n${GREEN}Checking if we can list DNS records for this zone...${NC}"
    # Use a clean URL
    API_URL="https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records"
    echo -e "Using URL: ${API_URL}"
    echo -e "Headers: X-Auth-Email: ${CLOUDFLARE_EMAIL}, X-Auth-Key: ${CLOUDFLARE_API_KEY:0:5}..."
    
    DNS_LIST=$(curl -s -v -X GET "${API_URL}" \
         -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
         -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
         -H "Content-Type: application/json" 2>&1)
    
    echo -e "Raw response: $DNS_LIST"
    
    if [[ "$DNS_LIST" == *'"success":true'* ]]; then
        echo -e "${GREEN}Successfully listed DNS records!${NC}"
        RECORD_COUNT=$(echo $DNS_LIST | grep -o '"count":[0-9]*' | cut -d':' -f2)
        echo -e "Found ${RECORD_COUNT} DNS records in this zone."
    else
        echo -e "${RED}Failed to list DNS records.${NC}"
        echo -e "${YELLOW}This could be due to:${NC}"
        echo -e "1. API key permissions are insufficient (need 'DNS:Edit' permission)"
        echo -e "2. The API key might be invalid or expired"
        echo -e "3. Rate limiting or other Cloudflare API restrictions"
    fi
    
    # Try creating a simple test record to verify write permissions
    echo -e "\n${GREEN}Attempting to create a test DNS record...${NC}"
    API_CREATE_URL="https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records"
    TEST_RECORD=$(curl -s -v -X POST "${API_CREATE_URL}" \
         -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
         -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"TXT\",\"name\":\"test\",\"content\":\"API test record\",\"ttl\":1}" 2>&1)
    
    echo -e "Raw response: $TEST_RECORD"
    
    if [[ "$TEST_RECORD" == *'"success":true'* ]]; then
        echo -e "${GREEN}Successfully created a test DNS record!${NC}"
        echo -e "This confirms your API key has the proper permissions."
        
        # Get the record ID to delete it
        RECORD_ID=$(echo $TEST_RECORD | grep -o '"id":"[^"]*' | cut -d'"' -f4)
        
        # Delete the test record
        echo -e "\n${GREEN}Cleaning up the test record...${NC}"
        DELETE_URL="https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}"
        DELETE_RECORD=$(curl -s -X DELETE "${DELETE_URL}" \
             -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
             -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
             -H "Content-Type: application/json")
        
        if [[ "$DELETE_RECORD" == *'"success":true'* ]]; then
            echo -e "${GREEN}Test record cleaned up successfully.${NC}"
        else
            echo -e "${YELLOW}Note: Could not clean up test record, but this is not critical.${NC}"
        fi
    else
        echo -e "${RED}Failed to create a test DNS record.${NC}"
        echo -e "${YELLOW}This confirms there is an issue with API permissions.${NC}"
        echo -e "Please ensure your Cloudflare API key has the 'DNS:Edit' permission."
        
        echo -e "\n${YELLOW}API key troubleshooting:${NC}"
        echo -e "1. Log in to your Cloudflare account"
        echo -e "2. Navigate to My Profile > API Tokens"
        echo -e "3. Verify your Global API Key or create a new API Token with Zone:DNS:Edit permission"
    fi
else
    echo -e "${RED}Error checking zone:${NC}"
    echo -e "Error details: $ZONE_CHECK"
fi

echo -e "\n${GREEN}Cloudflare API test complete!${NC}"
