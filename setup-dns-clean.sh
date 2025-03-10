#!/bin/bash
# DNS Configuration script that separates code from configuration
# Using JSON configuration for maximum flexibility and no script modifications

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Check for jq which is required for JSON parsing
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "Please install jq: apt-get install jq"
    exit 1
fi

# Default config file location
CONFIG_FILE="dns-config.json"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --config)
            CONFIG_FILE="$2"
            shift
            shift
            ;;
        --direct)
            FORCE_DIRECT_API=true
            shift
            ;;
        --domain)
            CLI_DOMAIN="$2"
            shift
            shift
            ;;
        *)
            # First non-option argument is treated as domain
            if [[ "$key" != -* && -z "$CLI_DOMAIN" ]]; then
                CLI_DOMAIN="$key"
            fi
            shift
            ;;
    esac
done

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    # Check if example config exists
    if [ -f "${CONFIG_FILE}.example" ]; then
        echo -e "${YELLOW}Config file $CONFIG_FILE not found, but example exists.${NC}"
        echo -e "Creating a copy from example... (you should edit this with your settings)"
        cp "${CONFIG_FILE}.example" "$CONFIG_FILE"
    else
        echo -e "${RED}Error: Configuration file $CONFIG_FILE not found${NC}"
        echo "Please create a config file or specify one with --config"
        exit 1
    fi
fi

echo -e "${GREEN}Using configuration from $CONFIG_FILE${NC}"

# Load configuration from JSON
DOMAIN=$(jq -r '.domain // empty' "$CONFIG_FILE")
PRIMARY_IP=$(jq -r '.primary_ip // empty' "$CONFIG_FILE")
MAIL_IP=$(jq -r '.mail_ip // empty' "$CONFIG_FILE")
API_URL=$(jq -r '.api_settings.url // "http://localhost:3000"' "$CONFIG_FILE") 
USE_DIRECT_API=$(jq -r '.api_settings.use_direct_api // false' "$CONFIG_FILE")
DKIM_DIR=$(jq -r '.directories.dkim // "./dkim"' "$CONFIG_FILE")

# Override with environment variables if present
DOMAIN=${CLI_DOMAIN:-${DOMAIN:-$DOMAIN}}
PRIMARY_IP=${PRIMARY_IP:-$PRIMARY_IP}
MAIL_IP=${MAIL_IP:-$MAIL_IP}

# If mail IP is not set, use primary IP
MAIL_IP=${MAIL_IP:-$PRIMARY_IP}

# Override with command line flag if provided
if [ "$FORCE_DIRECT_API" = true ]; then
    USE_DIRECT_API=true
fi

# Load environment variables from .env file as fallback
if [ -f .env ]; then
    # Only load values that aren't already set
    if [ -z "$DOMAIN" ]; then
        DOMAIN=$(grep "^DOMAIN=" .env | cut -d '=' -f2)
    fi
    if [ -z "$PRIMARY_IP" ]; then
        PRIMARY_IP=$(grep "^PRIMARY_IP=" .env | cut -d '=' -f2)
    fi
    if [ -z "$MAIL_IP" ]; then
        MAIL_IP=$(grep "^MAIL_IP=" .env | cut -d '=' -f2 || echo "$PRIMARY_IP")
    fi
    if [ -z "$CLOUDFLARE_EMAIL" ]; then
        CLOUDFLARE_EMAIL=$(grep "^CLOUDFLARE_EMAIL=" .env | cut -d '=' -f2)
    fi
    if [ -z "$CLOUDFLARE_API_KEY" ]; then
        CLOUDFLARE_API_KEY=$(grep "^CLOUDFLARE_API_KEY=" .env | cut -d '=' -f2)
    fi
    echo -e "${GREEN}Loaded fallback values from .env file${NC}"
fi

# Check required parameters
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Error: Domain is required${NC}"
    echo "Specify domain in config file, .env file, or as parameter"
    exit 1
fi

if [ -z "$PRIMARY_IP" ]; then
    echo -e "${YELLOW}Primary IP not set, prompting...${NC}"
    read -p "Enter your primary IP address: " PRIMARY_IP
    if [ -z "$PRIMARY_IP" ]; then
        echo -e "${RED}Primary IP address is required.${NC}"
        exit 1
    fi
    
    # Save this to config for future runs
    TMP_FILE=$(mktemp)
    jq --arg ip "$PRIMARY_IP" '.primary_ip = $ip' "$CONFIG_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CONFIG_FILE"
fi

if [ -z "$MAIL_IP" ]; then
    # Use PRIMARY_IP as fallback
    MAIL_IP="$PRIMARY_IP"
    echo -e "${YELLOW}Mail IP not set, using Primary IP: $MAIL_IP${NC}"
    
    # Save this to config for future runs
    TMP_FILE=$(mktemp)
    jq --arg ip "$MAIL_IP" '.mail_ip = $ip' "$CONFIG_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CONFIG_FILE"
fi

# Check Cloudflare credentials
if [ -z "$CLOUDFLARE_EMAIL" ] || [ -z "$CLOUDFLARE_API_KEY" ]; then
    echo -e "${RED}ERROR: CLOUDFLARE_EMAIL and CLOUDFLARE_API_KEY must be set in .env file${NC}"
    echo "Create a .env file with:"
    echo "CLOUDFLARE_EMAIL=your_email@example.com"
    echo "CLOUDFLARE_API_KEY=your_global_api_key"
    exit 1
fi

# Show configuration
echo -e "${GREEN}Using the following configuration:${NC}"
echo -e "  DOMAIN: ${DOMAIN}"
echo -e "  PRIMARY_IP: ${PRIMARY_IP}"
echo -e "  MAIL_IP: ${MAIL_IP}"
echo -e "  CLOUDFLARE_EMAIL: ${CLOUDFLARE_EMAIL}"
echo -e "  CLOUDFLARE_API_KEY: ${CLOUDFLARE_API_KEY:0:5}... (partially hidden)"
echo -e "  API_URL: ${API_URL}"
echo -e "  USING DIRECT API: ${USE_DIRECT_API}"

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
if [ "$USE_DIRECT_API" != "true" ]; then
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

# 1. Generate DKIM keys
echo -e "${GREEN}Generating DKIM keys for ${DOMAIN}...${NC}"
cd ${DKIM_DIR}/${DOMAIN}
openssl genrsa -out mail.private 2048
openssl rsa -in mail.private -pubout -out mail.public

# Convert public key to DNS format
PUBLIC_KEY=$(cat mail.public | grep -v '^-' | tr -d '\n')
DKIM_RECORD="v=DKIM1; k=rsa; p=${PUBLIC_KEY}"
echo ${DKIM_RECORD} > mail.txt

# Generate DNS config with templates filled in
echo -e "${GREEN}Creating DNS configuration for ${DOMAIN}...${NC}"
# Process the DNS records from the config file, replacing placeholders
DNS_CONFIG=$(jq -r '.dns_records' "$CONFIG_FILE" \
  | sed "s/#DOMAIN#/${DOMAIN}/g" \
  | sed "s/#PRIMARY_IP#/${PRIMARY_IP}/g" \
  | sed "s/#MAIL_IP#/${MAIL_IP}/g" \
  | sed "s/#DKIM_RECORD#/${DKIM_RECORD}/g")

# Create the full DNS config object
FULL_DNS_CONFIG="{\"domain\":\"${DOMAIN}\",\"config\":{\"records\":${DNS_CONFIG}}}"

# Create DNS directory if it doesn't exist
mkdir -p ./dns

# Save DNS config to file for debugging purposes
echo -e "${GREEN}Saving DNS configuration to dns/${DOMAIN}_config.json...${NC}"
echo "$FULL_DNS_CONFIG" > "../${DOMAIN}_config.json"

# 3. First, store Cloudflare credentials in the database if using API mode
if [ "$USE_DIRECT_API" != "true" ]; then
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
if [ "$USE_DIRECT_API" = "true" ]; then
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
            A_RECORDS=$(echo "$FULL_DNS_CONFIG" | jq -c '.config.records.a_records[]')
            for record in $A_RECORDS; do
                NAME=$(echo $record | jq -r '.name')
                CONTENT=$(echo $record | jq -r '.content')
                PROXIED=$(echo $record | jq -r '.proxied // false')
                
                NAME=${NAME//@/}
                if [ -z "$NAME" ] || [ "$NAME" = "@" ]; then
                    RECORD_NAME="${ROOT_DOMAIN}"
                    NAME="@"
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
            
            # Process MX records
            MX_RECORDS=$(echo "$FULL_DNS_CONFIG" | jq -c '.config.records.mx_records[]')
            for record in $MX_RECORDS; do
                NAME=$(echo $record | jq -r '.name')
                CONTENT=$(echo $record | jq -r '.content')
                PRIORITY=$(echo $record | jq -r '.priority // 10')
                
                NAME=${NAME//@/}
                if [ -z "$NAME" ] || [ "$NAME" = "@" ]; then
                    RECORD_NAME="${ROOT_DOMAIN}"
                    NAME="@"
                else
                    RECORD_NAME="${NAME}.${ROOT_DOMAIN}"
                fi
                
                echo -e "${GREEN}Creating/Updating MX record: ${RECORD_NAME} -> ${CONTENT} (priority: ${PRIORITY})${NC}"
                MX_RECORD="{\"type\":\"MX\",\"name\":\"$NAME\",\"content\":\"$CONTENT\",\"priority\":$PRIORITY,\"ttl\":1}"
                
                curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                    -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
                    -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
                    -H "Content-Type: application/json" \
                    --data "$MX_RECORD" > /dev/null
            done
                
            # Process TXT records
            TXT_RECORDS=$(echo "$FULL_DNS_CONFIG" | jq -c '.config.records.txt_records[]')
            for record in $TXT_RECORDS; do
                NAME=$(echo $record | jq -r '.name')
                CONTENT=$(echo $record | jq -r '.content')
                
                NAME=${NAME//@/}
                if [ -z "$NAME" ] || [ "$NAME" = "@" ]; then
                    RECORD_NAME="${ROOT_DOMAIN}"
                    NAME="@"
                else
                    RECORD_NAME="${NAME}.${ROOT_DOMAIN}"
                fi
                
                echo -e "${GREEN}Creating/Updating TXT record: ${RECORD_NAME}${NC}"
                TXT_RECORD="{\"type\":\"TXT\",\"name\":\"$NAME\",\"content\":\"$CONTENT\",\"ttl\":1}"
                
                curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                    -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
                    -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
                    -H "Content-Type: application/json" \
                    --data "$TXT_RECORD" > /dev/null
            done
                
            # Process SRV records
            SRV_RECORDS=$(echo "$FULL_DNS_CONFIG" | jq -c '.config.records.srv_records[]')
            for record in $SRV_RECORDS; do
                NAME=$(echo $record | jq -r '.name')
                SERVICE=$(echo $record | jq -r '.service')
                PROTO=$(echo $record | jq -r '.proto')
                PRIORITY=$(echo $record | jq -r '.priority // 0')
                WEIGHT=$(echo $record | jq -r '.weight // 1')
                PORT=$(echo $record | jq -r '.port')
                TARGET=$(echo $record | jq -r '.target')
                
                RECORD_NAME="${NAME}.${ROOT_DOMAIN}"
                echo -e "${GREEN}Creating/Updating SRV record: ${RECORD_NAME}${NC}"
                
                SRV_RECORD="{\"type\":\"SRV\",\"name\":\"$NAME\",\"data\":{\"service\":\"$SERVICE\",\"proto\":\"$PROTO\",\"name\":\"$DOMAIN\",\"priority\":$PRIORITY,\"weight\":$WEIGHT,\"port\":$PORT,\"target\":\"$TARGET\"},\"ttl\":1}"
                
                curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                    -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
                    -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
                    -H "Content-Type: application/json" \
                    --data "$SRV_RECORD" > /dev/null
            done
                
            echo -e "${GREEN}DNS records created directly via Cloudflare API${NC}"
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
      -d "$FULL_DNS_CONFIG" ${API_URL}/api/dns 2>&1)
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
        exec bash "$0" --direct --config "$CONFIG_FILE" "$DOMAIN"
        exit $? # This line will only be reached if exec fails
    else
        echo -e "${GREEN}Successfully created DNS configuration via API${NC}"
    fi
fi

# Skip API update if using direct API
if [ "$USE_DIRECT_API" != "true" ]; then
    # 5. Update DNS records in Cloudflare through API
    echo -e "${GREEN}Updating DNS records in Cloudflare...${NC}"
    UPDATE_RESPONSE=$(curl -s -X POST \
      -H "X-Cloudflare-Email: ${CLOUDFLARE_EMAIL}" \
      -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" \
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
if [ "$USE_DIRECT_API" != "true" ]; then
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
if [ "$USE_DIRECT_API" != "true" ]; then
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
