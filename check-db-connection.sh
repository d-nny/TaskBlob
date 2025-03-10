#!/bin/bash
# Script to diagnose and fix database connection issues

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}TaskBlob Database Connection Diagnostic Tool${NC}"
echo "==============================================="

# Load environment variables from .env file
if [ -f .env ]; then
  echo -e "${GREEN}Loading environment variables from .env file...${NC}"
  export $(grep -v '^#' .env | xargs)
else
  echo -e "${RED}.env file not found. Please create it with database credentials.${NC}"
  exit 1
fi

# Check if database container is running
echo -e "\n${YELLOW}Checking if PostgreSQL container is running...${NC}"
POSTGRES_CONTAINER=$(docker ps | grep postgres)
if [ -z "$POSTGRES_CONTAINER" ]; then
  echo -e "${RED}PostgreSQL container is not running!${NC}"
  echo -e "${YELLOW}Checking if container exists but is stopped...${NC}"
  
  STOPPED_CONTAINER=$(docker ps -a | grep postgres)
  if [ -n "$STOPPED_CONTAINER" ]; then
    echo -e "${YELLOW}Found stopped PostgreSQL container. Attempting to start it...${NC}"
    docker start postgres
    sleep 5
    
    # Check if it started successfully
    if [ -z "$(docker ps | grep postgres)" ]; then
      echo -e "${RED}Failed to start PostgreSQL container.${NC}"
    else
      echo -e "${GREEN}Successfully started PostgreSQL container!${NC}"
    fi
  else
    echo -e "${RED}PostgreSQL container does not exist. You may need to run:${NC}"
    echo "docker-compose up -d postgres"
  fi
else
  echo -e "${GREEN}PostgreSQL container is running.${NC}"
fi

# Get container IP
echo -e "\n${YELLOW}Checking PostgreSQL container IP address...${NC}"
POSTGRES_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' postgres)
if [ -z "$POSTGRES_IP" ]; then
  echo -e "${RED}Could not determine PostgreSQL container IP.${NC}"
else
  echo -e "${GREEN}PostgreSQL container IP: $POSTGRES_IP${NC}"
  
  # Check if this IP matches what's in the logs
  echo -e "${YELLOW}Verify this IP matches the connection error in your logs${NC}"
  echo -e "(Your logs showed connection attempt to 172.18.0.2)"
fi

# Check if config-api can reach the database
echo -e "\n${YELLOW}Checking if config-api container can reach the database...${NC}"
RESULT=$(docker exec config-api ping -c 1 $POSTGRES_IP 2>&1)
if [[ $RESULT == *"100% packet loss"* || $RESULT == *"command not found"* ]]; then
  echo -e "${RED}Config-api container cannot reach PostgreSQL!${NC}"
  echo -e "${YELLOW}Checking network configuration...${NC}"
  
  # Check if they're on the same network
  POSTGRES_NETWORK=$(docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' postgres)
  API_NETWORK=$(docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' config-api)
  
  echo -e "PostgreSQL network: $POSTGRES_NETWORK"
  echo -e "Config-api network: $API_NETWORK"
  
  if [ "$POSTGRES_NETWORK" != "$API_NETWORK" ]; then
    echo -e "${RED}Containers are on different networks!${NC}"
    echo -e "${YELLOW}You need to ensure both containers are on the same Docker network.${NC}"
  fi
else
  echo -e "${GREEN}Network connectivity from config-api to PostgreSQL looks good.${NC}"
fi

# Try connecting directly to verify PostgreSQL is accepting connections
echo -e "\n${YELLOW}Attempting to connect to PostgreSQL directly...${NC}"
POSTGRES_RUNNING=$(docker exec postgres pg_isready -h localhost 2>&1)
if [[ $POSTGRES_RUNNING == *"accepting connections"* ]]; then
  echo -e "${GREEN}PostgreSQL is up and accepting connections internally.${NC}"
else
  echo -e "${RED}PostgreSQL is not accepting connections internally: $POSTGRES_RUNNING${NC}"
  echo -e "${YELLOW}The database may not be fully initialized yet.${NC}"
fi

# Check if tables exist (with credentials from .env)
echo -e "\n${YELLOW}Checking if DNSConfigs table exists...${NC}"
TABLE_CHECK=$(docker exec postgres psql -U ${POSTGRES_USER:-postgres} -d ${POSTGRES_DB:-postgres} -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'DNSConfigs');" -t 2>&1)
if [[ $TABLE_CHECK == *"ERROR"* ]]; then
  echo -e "${RED}Failed to check table existence: $TABLE_CHECK${NC}"
else
  if [[ $TABLE_CHECK == *"t"* ]]; then
    echo -e "${GREEN}DNSConfigs table exists!${NC}"
  else
    echo -e "${RED}DNSConfigs table does not exist.${NC}"
    
    # Create the table manually
    echo -e "${YELLOW}Creating DNSConfigs table manually...${NC}"
    CREATE_TABLE=$(docker exec postgres psql -U ${POSTGRES_USER:-postgres} -d ${POSTGRES_DB:-postgres} -c "
      CREATE TABLE IF NOT EXISTS \"DNSConfigs\" (
        \"domain\" VARCHAR(255) PRIMARY KEY,
        \"config\" JSONB NOT NULL,
        \"lastUpdated\" TIMESTAMP WITH TIME ZONE,
        \"active\" BOOLEAN DEFAULT true,
        \"createdAt\" TIMESTAMP WITH TIME ZONE NOT NULL,
        \"updatedAt\" TIMESTAMP WITH TIME ZONE NOT NULL
      );" 2>&1)
    
    if [[ $CREATE_TABLE == *"ERROR"* ]]; then
      echo -e "${RED}Failed to create table: $CREATE_TABLE${NC}"
    else
      echo -e "${GREEN}DNSConfigs table created successfully!${NC}"
    fi
  fi
fi

# Restart the config-api container
echo -e "\n${YELLOW}Restarting config-api container...${NC}"
docker restart config-api
echo -e "${GREEN}Config-api container restarted.${NC}"

echo -e "\n${GREEN}Diagnostic complete!${NC}"
echo "You can check the config-api logs with: docker logs config-api"
