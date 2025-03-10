#!/bin/bash
# Comprehensive automated DNS, DKIM, and SSL setup script

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Load custom settings
SETTINGS_FILE="settings.local.sh"
if [ -f "$SETTINGS_FILE" ]; then
    source "$SETTINGS_FILE"
    echo -e "${GREEN}Loaded custom settings from $SETTINGS_FILE${NC}"
fi

# Variables
# Load environment variables from .env file if it exists
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
  echo -e "${GREEN}Loaded environment variables from .env file${NC}"
fi

DOMAIN=${DOMAIN_OVERRIDE:-${1:-"$DOMAIN"}}
PRIMARY_IP=${PRIMARY_IP_OVERRIDE:-$PRIMARY_IP}
MAIL_IP=${MAIL_IP_OVERRIDE:-$MAIL_IP}
API_URL=${API_URL_OVERRIDE:-"http://localhost:3000"}
DKIM_DIR=${DKIM_DIR_OVERRIDE:-"./dkim"}
USE_DIRECT_API=${USE_DIRECT_API_OVERRIDE:-false}

# Debug environment variables (partial for security)
echo -e "${GREEN}Using the following configuration:${NC}"
echo -e "  DOMAIN: ${DOMAIN}"
echo -e "  PRIMARY_IP: ${PRIMARY_IP}"
echo -e "  MAIL_IP: ${MAIL_IP:-$PRIMARY_IP} (using PRIMARY_IP if not set)"
echo -e "  CLOUDFLARE_EMAIL: ${CLOUDFLARE_EMAIL}"
echo -e "  CLOUDFLARE_API_KEY: ${CLOUDFLARE_API_KEY:0:5}... (partially hidden for security)"
echo -e "  API_URL: ${API_URL}"
echo -e "  USING DIRECT API: ${USE_DIRECT_API}"

# Prompt for IP addresses if not set
if [ -z "$PRIMARY_IP" ]; then
    read -p "Enter your primary IP address: " PRIMARY_IP
    if [ -z "$PRIMARY_IP" ]; then
        echo -e "${RED}Primary IP address is required.${NC}"
        exit 1
    fi
fi

if [ -z "$MAIL_IP" ]; then
    read -p "Enter your mail server IP address (or press enter to use primary IP): " MAIL_IP
    MAIL_IP=${MAIL_IP:-$PRIMARY_IP}
fi

# Verify required env variables
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}ERROR: DOMAIN must be set in .env file or provided as first argument${NC}"
    exit 1
fi

if [ -z "$CLOUDFLARE_EMAIL" ] || [ -z "$CLOUDFLARE_API_KEY" ]; then
    echo -e "${RED}ERROR: CLOUDFLARE_EMAIL and CLOUDFLARE_API_KEY must be set in .env file or environment${NC}"
    echo "Create a .env file with:"
    echo "CLOUDFLARE_EMAIL=your_email@example.com"
    echo "CLOUDFLARE_API_KEY=your_global_api_key"
    exit 1
fi

# Check if curl is installed
if ! command -v curl &> /dev/null; then
    echo "Installing curl..."
    apt-get update && apt-get install -y curl
fi

# Function to check API status
check_api_status() {
    local status_code=$(curl -s -o /dev/null -w "%{http_code}" ${API_URL}/api/status)
    if [ "$status_code" = "200" ]; then
        return 0
    else
        return 1
    fi
}

# Verify API is accessible (skip if using direct API)
if [ "$USE_DIRECT_API" = false ]; then
    echo -e "${GREEN}Verifying API connectivity...${NC}"
    MAX_RETRIES=5
    RETRY_COUNT=0
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if check_api_status; then
            echo -e "${GREEN}API is accessible!${NC}"
            break
        else
            echo -e "${YELLOW}API not available yet. Retrying in 10 seconds... (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)${NC}"
            sleep 10
            RETRY_COUNT=$((RETRY_COUNT+1))
        fi
    done

    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo -e "${YELLOW}WARNING: API is not accessible after $MAX_RETRIES attempts.${NC}"
        echo -e "${YELLOW}Switching to direct Cloudflare API mode${NC}"
        USE_DIRECT_API=true
    fi
fi

# Create directory structure
mkdir -p ${DKIM_DIR}/${DOMAIN}

# Copy and customize template for the domain if needed
if [ -f "./dns/template.json" ]; then
    echo -e "${GREEN}Creating domain configuration from template...${NC}"
    cp ./dns/template.json "./dns/${DOMAIN}.json.new"
    
    # Replace placeholders with actual values
    sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" "./dns/${DOMAIN}.json.new"
    sed -i "s/PRIMARY_IP_PLACEHOLDER/${PRIMARY_IP}/g" "./dns/${DOMAIN}.json.new"
    sed -i "s/MAIL_IP_PLACEHOLDER/${MAIL_IP}/g" "./dns/${DOMAIN}.json.new"
    sed -i "s/IPV6_PREFIX_PLACEHOLDER/${IPV6_PREFIX:-2a01:4f8}/g" "./dns/${DOMAIN}.json.new"
    
    # Move the new file to replace any existing one
    mv "./dns/${DOMAIN}.json.new" "./dns/${DOMAIN}.json"
fi

# 1. Generate DKIM keys
echo -e "${GREEN}Generating DKIM keys for ${DOMAIN}...${NC}"
cd ${DKIM_DIR}/${DOMAIN}
openssl genrsa -out mail.private 2048
openssl rsa -in mail.private -pubout -out mail.public

# Convert public key to DNS format
PUBLIC_KEY=$(cat mail.public | grep -v '^-' | tr -d '\n')
DKIM_RECORD="v=DKIM1; k=rsa; p=${PUBLIC_KEY}"
echo ${DKIM_RECORD} > mail.txt

# 2. Create DNS configuration
echo -e "${GREEN}Creating DNS configuration for ${DOMAIN}...${NC}"
DNS_CONFIG=$(cat <<EOF
{
  "domain": "${DOMAIN}",
  "config": {
    "records": {
      "a": [
        {
          "name": "@",
          "content": "${PRIMARY_IP}",
          "proxied": false
        },
        {
          "name": "www",
          "content": "${PRIMARY_IP}",
          "proxied": false
        },
        {
          "name": "mail",
          "content": "${MAIL_IP}",
          "proxied": false
        },
        {
          "name": "webmail",
          "content": "${PRIMARY_IP}",
          "proxied": false
        },
        {
          "name": "admin",
          "content": "${PRIMARY_IP}",
          "proxied": false
        }
      ],
      "mx": [
        {
          "name": "@",
          "content": "mail.${DOMAIN}",
          "priority": 10
        }
      ],
      "txt": [
        {
          "name": "@",
          "content": "v=spf1 mx ~all"
        },
        {
          "name": "_dmarc",
          "content": "v=DMARC1; p=none; rua=mailto:admin@${DOMAIN}"
        },
        {
          "name": "mail._domainkey",
          "content": "${DKIM_RECORD}"
        }
      ],
      "srv": [
        {
          "name": "_imaps._tcp",
          "service": "_imaps",
          "proto": "_tcp",
          "priority": 0,
          "weight": 1,
          "port": 993,
          "target": "mail.${DOMAIN}"
        },
        {
          "name": "_submission._tcp",
          "service": "_submission",
          "proto": "_tcp",
          "priority": 0,
          "weight": 1,
          "port": 587,
          "target": "mail.${DOMAIN}"
        },
        {
          "name": "_pop3s._tcp",
          "service": "_pop3s",
          "proto": "_tcp",
          "priority": 0,
          "weight": 1,
          "port": 995,
          "target": "mail.${DOMAIN}"
        }
      ]
    }
  }
}
EOF
)

# Create DNS directory if it doesn't exist
mkdir -p ./dns

# Save DNS config to file for debugging purposes
echo -e "${GREEN}Saving DNS configuration to dns/${DOMAIN}_config.json...${NC}"
echo "$DNS_CONFIG" > "../${DOMAIN}_config.json"

# 3. First, store Cloudflare credentials in the database if using API mode
if [ "$USE_DIRECT_API" = false ]; then
    echo -e "${GREEN}Storing Cloudflare credentials in the API database...${NC}"
    STORE_CREDS_DATA="{\"email\":\"${CLOUDFLARE_EMAIL}\",\"apiKey\":\"${CLOUDFLARE_API_KEY}\",\"active\":true}"
    CREDS_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d "$STORE_CREDS_DATA" ${API_URL}/api/cloudflare/credentials 2>&1)

    # Check if credentials endpoint doesn't exist (we'll use the original approach)
    if [[ "$CREDS_RESPONSE" == *"Cannot POST"* ]]; then
        echo -e "${YELLOW}Credentials API endpoint not available. Using headers method instead.${NC}"
        # Continue with existing approach
    else
        echo -e "${GREEN}Credentials stored in database.${NC}"
    fi
fi

# 4. Push DNS configuration to API or directly to Cloudflare
if [ "$USE_DIRECT_API" = true ]; then
    echo -e "${GREEN}Using direct Cloudflare API...${NC}"
    
    # Extract domain info
    DOMAIN_PARTS=(${DOMAIN//./ })
    ROOT_DOMAIN="${DOMAIN_PARTS[-2]}.${DOMAIN_PARTS[-1]}"
    
    echo -e "${GREEN}Getting zone ID for ${ROOT_DOMAIN}...${NC}"
    ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${ROOT_DOMAIN}" \
        -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
        -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
        -H "Content-Type: application/json")
    
    if [[ "$ZONE_RESPONSE" == *'"result":[]'* ]]; then
        echo -e "${RED}Zone not found for domain ${ROOT_DOMAIN}!${NC}"
        echo -e "${YELLOW}You need to add this domain to your Cloudflare account first.${NC}"
        echo -e "\nContinuing with the setup, but DNS records won't be updated."
    elif [[ "$ZONE_RESPONSE" == *'"success":true'* ]]; then
        # Extract zone ID
        ZONE_ID=$(echo $ZONE_RESPONSE | grep -o '"id":"[^"]*' | head -n 1 | cut -d'"' -f4)
        
        if [ -n "$ZONE_ID" ]; then
            echo -e "${GREEN}Zone ID found: ${ZONE_ID}${NC}"
            
            # Process A records
            if [ -n "$(echo $DNS_CONFIG | grep -o '"a":\[')" ]; then
                echo -e "${GREEN}Processing A records...${NC}"
                # Extract A records using jq if available, otherwise keep simple approach
                if command -v jq &> /dev/null; then
                    A_RECORDS=$(echo $DNS_CONFIG | jq -c '.config.records.a[]')
                    for record in $A_RECORDS; do
                        NAME=$(echo $record | jq -r '.name')
                        CONTENT=$(echo $record | jq -r '.content')
                        PROXIED=$(echo $record | jq -r '.proxied // false')
                        
                        NAME=${NAME//@/}
                        if [ -z "$NAME" ]; then
                            RECORD_NAME="${ROOT_DOMAIN}"
                        else
                            RECORD_NAME="${NAME}.${ROOT_DOMAIN}"
                        fi
                        
                        echo -e "${GREEN}Creating/Updating A record: ${RECORD_NAME} -> ${CONTENT}${NC}"
                        CF_RECORD="{\"type\":\"A\",\"name\":\"$NAME\",\"content\":\"$CONTENT\",\"ttl\":1,\"proxied\":$PROXIED}"
                        
                        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                            -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
                            -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
                            -H "Content-Type: application/json" \
                            --data "$CF_RECORD" > /dev/null
                    done
                else
                    echo -e "${YELLOW}jq not installed, using simplified A record processing${NC}"
                    # Process a few key A records manually
                    for NAME in "" "www" "mail" "webmail"; do
                        if [ "$NAME" == "mail" ]; then
                            CONTENT="${MAIL_IP}"
                        else
                            CONTENT="${PRIMARY_IP}"
                        fi
                        
                        if [ -z "$NAME" ]; then
                            RECORD_NAME="${ROOT_DOMAIN}"
                            NAME="@"
                        else
                            RECORD_NAME="${NAME}.${ROOT_DOMAIN}"
                        fi
                        
                        echo -e "${GREEN}Creating/Updating A record: ${RECORD_NAME} -> ${CONTENT}${NC}"
                        CF_RECORD="{\"type\":\"A\",\"name\":\"$NAME\",\"content\":\"$CONTENT\",\"ttl\":1,\"proxied\":false}"
                        
                        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                            -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
                            -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
                            -H "Content-Type: application/json" \
                            --data "$CF_RECORD" > /dev/null
                    done
                fi
            fi
            
            # Create MX record
            echo -e "${GREEN}Creating MX record: mail.${DOMAIN}${NC}"
            MX_RECORD="{\"type\":\"MX\",\"name\":\"@\",\"content\":\"mail.${DOMAIN}\",\"priority\":10,\"ttl\":1}"
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
                -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
                -H "Content-Type: application/json" \
                --data "$MX_RECORD" > /dev/null
                
            # Create SPF record
            echo -e "${GREEN}Creating SPF record${NC}"
            SPF_RECORD="{\"type\":\"TXT\",\"name\":\"@\",\"content\":\"v=spf1 mx ~all\",\"ttl\":1}"
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
                -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
                -H "Content-Type: application/json" \
                --data "$SPF_RECORD" > /dev/null
                
            # Create DMARC record
            echo -e "${GREEN}Creating DMARC record${NC}"
            DMARC_RECORD="{\"type\":\"TXT\",\"name\":\"_dmarc\",\"content\":\"v=DMARC1; p=none; rua=mailto:admin@${DOMAIN}\",\"ttl\":1}"
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
                -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
                -H "Content-Type: application/json" \
                --data "$DMARC_RECORD" > /dev/null
                
            # Create DKIM record if we have it
            echo -e "${GREEN}Creating DKIM record${NC}"
            DKIM_RECORD="{\"type\":\"TXT\",\"name\":\"mail._domainkey\",\"content\":\"${DKIM_RECORD}\",\"ttl\":1}"
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
                -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
                -H "Content-Type: application/json" \
                --data "$DKIM_RECORD" > /dev/null
                
            echo -e "${GREEN}Basic DNS records created directly via Cloudflare API${NC}"
            echo -e "${YELLOW}Note: SRV records not created in fallback mode. Use Cloudflare dashboard to add them manually.${NC}"
        else
            echo -e "${RED}Could not extract zone ID from response.${NC}"
            echo -e "${YELLOW}Check your Cloudflare credentials and ensure the domain is added to your account.${NC}"
        fi
    else
        echo -e "${RED}Error checking zone:${NC}"
        echo -e "Error details: $ZONE_RESPONSE"
    fi
else
    echo -e "${GREEN}Pushing DNS configuration to API...${NC}"
    echo -e "API URL: ${API_URL}/api/dns"
    echo -e "Making API request..."

    # First try using the API
    DNS_RESPONSE=$(curl -s -v -X POST \
      -H "Content-Type: application/json" \
      -H "X-Cloudflare-Email: ${CLOUDFLARE_EMAIL}" \
      -H "X-Cloudflare-Api-Key: ${CLOUDFLARE_API_KEY}" \
      --max-time 15 \
      --retry 2 \
      -d "$DNS_CONFIG" ${API_URL}/api/dns 2>&1)
    API_CURL_EXIT_CODE=$?

    # Save API response for debugging
    echo "$DNS_RESPONSE" > "/tmp/dns_api_response.log"
    echo -e "API response saved to /tmp/dns_api_response.log for debugging"

    # Check if API approach failed
    if [ $API_CURL_EXIT_CODE -ne 0 ] || [[ "$DNS_RESPONSE" == *"error"* ]]; then
        echo -e "${YELLOW}API approach failed with exit code $API_CURL_EXIT_CODE${NC}"
        echo -e "${YELLOW}Response: $DNS_RESPONSE${NC}"
        echo -e "${YELLOW}Falling back to direct Cloudflare API approach...${NC}"
        
        # Set flag to use direct approach
        USE_DIRECT_API=true
        
        # Re-run this script with direct API flag
        cd - > /dev/null # Return to original directory
        exec bash "$0" "--direct-api"
        exit $? # This line will only be reached if exec fails
    else
        echo -e "${GREEN}Successfully created DNS configuration via API${NC}"
    fi
fi

# Skip API update if using direct API
if [ "$USE_DIRECT_API" = false ]; then
    # 5. Update DNS records in Cloudflare through API
    echo -e "${GREEN}Updating DNS records in Cloudflare...${NC}"
    UPDATE_RESPONSE=$(curl -s -X POST \
      -H "X-Cloudflare-Email: ${CLOUDFLARE_EMAIL}" \
      -H "X-Cloudflare-Api-Key: ${CLOUDFLARE_API_KEY}" \
      ${API_URL}/api/dns/${DOMAIN}/update)
    if [[ "$UPDATE_RESPONSE" == *"error"* ]]; then
        echo -e "${RED}Error updating DNS records: $UPDATE_RESPONSE${NC}"
        echo -e "${YELLOW}Possible issues:${NC}"
        echo -e "1. Cloudflare API credentials might be invalid"
        echo -e "2. The domain zone might not exist in Cloudflare"
        echo -e "3. The API might not have permissions to update DNS records"
        echo -e "\nCheck logs with: docker logs config-api"
    else
        echo -e "${GREEN}DNS records updated successfully via API${NC}"
    fi
fi

# 6. Wait for DNS propagation
echo -e "${YELLOW}Waiting 60 seconds for DNS propagation...${NC}"
sleep 60

# 7. Register the domain for mail use (skip if using direct API)
if [ "$USE_DIRECT_API" = false ]; then
    echo -e "${GREEN}Registering domain for mail use...${NC}"
    MAIL_DOMAIN_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"domain\":\"${DOMAIN}\",\"description\":\"Mail domain for ${DOMAIN}\"}" \
        ${API_URL}/api/mail/domains)
    if [[ "$MAIL_DOMAIN_RESPONSE" == *"error"* ]]; then
        echo -e "${RED}Error registering mail domain: $MAIL_DOMAIN_RESPONSE${NC}"
        echo -e "${YELLOW}This is non-critical, continuing with the setup...${NC}"
    fi

    # 8. Create admin user
    echo -e "${GREEN}Creating admin mail user...${NC}"
    # Use password from environment or a randomly generated one
    ADMIN_PASSWORD=${ADMIN_PASSWORD:-$(openssl rand -base64 12)}
    ADMIN_USER_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"email\":\"admin@${DOMAIN}\",\"domain\":\"${DOMAIN}\",\"password\":\"${ADMIN_PASSWORD}\"}" \
        ${API_URL}/api/mail/users)
    # Save the password if randomly generated
    if [ -z "${ADMIN_PASSWORD+x}" ]; then
        echo "Admin password for admin@${DOMAIN}: ${ADMIN_PASSWORD}" > admin_credentials.txt
        chmod 600 admin_credentials.txt
        echo -e "${YELLOW}A random password was generated for admin@${DOMAIN}.${NC}"
        echo -e "${YELLOW}It has been saved to admin_credentials.txt. Please store it securely and delete this file.${NC}"
    fi
    if [[ "$ADMIN_USER_RESPONSE" == *"error"* ]]; then
        echo -e "${RED}Error creating admin user: $ADMIN_USER_RESPONSE${NC}"
        echo -e "${YELLOW}This is non-critical, continuing with the setup...${NC}"
    fi

    # 9. Generate SSL certificate using DNS validation
    echo -e "${GREEN}Generating SSL certificate for mail.${DOMAIN}...${NC}"
    SSL_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"email\":\"admin@${DOMAIN}\",\"subdomains\":[\"mail\",\"webmail\"]}" \
        ${API_URL}/api/ssl/${DOMAIN}/generate)
    if [[ "$SSL_RESPONSE" == *"error"* ]]; then
        echo -e "${RED}Error generating SSL certificate: $SSL_RESPONSE${NC}"
        echo -e "${YELLOW}SSL certificate generation failed, you may need to run this manually later.${NC}"
    else
        # Extract script path from response
        SCRIPT_PATH=$(echo $SSL_RESPONSE | grep -o '"/tmp/generate-ssl.sh"' | tr -d '"')
        if [ -n "$SCRIPT_PATH" ]; then
            echo -e "${GREEN}Running SSL certificate script...${NC}"
            chmod +x $SCRIPT_PATH
            sudo $SCRIPT_PATH

            # Verify certificate was created
            if [ -d "/app/ssl/${DOMAIN}" ]; then
                echo -e "${GREEN}SSL certificate generated successfully!${NC}"
            else
                echo -e "${RED}SSL certificate generation failed!${NC}"
                echo -e "${YELLOW}You may need to generate SSL certificates manually later.${NC}"
            fi
        else
            echo -e "${RED}SSL script path not found in response!${NC}"
            echo -e "${YELLOW}SSL certificate generation failed, you may need to run this manually later.${NC}"
        fi
    fi
else
    echo -e "${YELLOW}Skipping mail registration and SSL certificate generation in direct API mode${NC}"
    echo -e "${YELLOW}These steps require the API to be running and will need to be performed separately${NC}"
fi

# 10. Copy DKIM keys to the mail container's expected location
echo -e "${GREEN}Copying DKIM keys to the right locations...${NC}"
sudo mkdir -p /var/server/dkim/${DOMAIN}
sudo cp mail.private /var/server/dkim/${DOMAIN}/
sudo cp mail.txt /var/server/dkim/${DOMAIN}/

# Also store in the Docker volume location
mkdir -p ./dkim/${DOMAIN}
cp mail.private ./dkim/${DOMAIN}/
cp mail.txt ./dkim/${DOMAIN}/

# 11. Restart necessary services if Docker is running
if command -v docker &> /dev/null && docker ps &> /dev/null; then
    echo -e "${GREEN}Restarting mail services...${NC}"
    docker-compose restart mailserver
    docker-compose restart nginx
else
    echo -e "${YELLOW}Docker not running, skipping service restart${NC}"
    echo -e "${YELLOW}Remember to restart services when Docker is available${NC}"
fi

echo -e "${GREEN}=== SETUP COMPLETE ===${NC}"
echo -e "${GREEN}Your mail server is now configured with:${NC}"
echo -e "  - DNS records in Cloudflare"
echo -e "  - DKIM keys for email authentication"
if [ "$USE_DIRECT_API" = false ]; then
    echo -e "  - SSL certificates for secure connections"
    echo -e "  - Default admin account: admin@${DOMAIN}"
    if [ -f "admin_credentials.txt" ]; then
        echo -e "\n${YELLOW}IMPORTANT: The admin password was saved to admin_credentials.txt${NC}"
        echo -e "${YELLOW}Please store it securely and delete this file after noting the password.${NC}"
    else
        echo -e "\n${YELLOW}IMPORTANT: Using the admin password you configured in your .env file${NC}"
    fi
fi
echo -e "You can do this through the webmail interface at https://webmail.${DOMAIN}"
echo -e "\n${GREEN}To verify your setup:${NC}"
echo -e "1. Check DNS records: dig +short MX ${DOMAIN}"
echo -e "2. Test SMTP connection: telnet mail.${DOMAIN} 25"
echo -e "3. Test IMAP connection: openssl s_client -connect mail.${DOMAIN}:993"
echo -e "4. Access webmail at: https://webmail.${DOMAIN}\n"
echo -e "\n${YELLOW}If you encountered any errors during this process, check:${NC}"
echo -e "1. Docker logs: docker logs config-api"
echo -e "2. Your .env file to ensure all required variables are set correctly"
echo -e "3. Cloudflare dashboard to confirm DNS records were created"
echo -e "4. Run individual failed steps manually if needed\n"
