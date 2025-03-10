#!/bin/bash
# Script to fix admin panel login issues

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}TaskBlob Admin Panel Login Fix${NC}"
echo "==============================="

# Check if admin-panel container is running
echo -e "\n${YELLOW}Checking admin-panel container status...${NC}"
ADMIN_CONTAINER=$(docker ps | grep admin-panel)
if [ -z "$ADMIN_CONTAINER" ]; then
  echo -e "${RED}Admin panel container is not running!${NC}"
  echo -e "${YELLOW}Checking if container exists but is stopped...${NC}"
  
  STOPPED_CONTAINER=$(docker ps -a | grep admin-panel)
  if [ -n "$STOPPED_CONTAINER" ]; then
    echo -e "${YELLOW}Found stopped admin-panel container. Attempting to start it...${NC}"
    docker start admin-panel
    sleep 5
    
    # Check if it started successfully
    if [ -z "$(docker ps | grep admin-panel)" ]; then
      echo -e "${RED}Failed to start admin-panel container.${NC}"
    else
      echo -e "${GREEN}Successfully started admin-panel container!${NC}"
    fi
  else
    echo -e "${RED}Admin panel container does not exist. You may need to run:${NC}"
    echo "docker-compose up -d admin-panel"
  fi
else
  echo -e "${GREEN}Admin panel container is running.${NC}"
fi

# Check environment variables in admin-panel container
echo -e "\n${YELLOW}Checking admin panel environment variables...${NC}"
ADMIN_ENV=$(docker exec admin-panel env | grep ADMIN)

if [[ "$ADMIN_ENV" == *"ADMIN_USER"* ]] && [[ "$ADMIN_ENV" == *"ADMIN_PASSWORD"* ]]; then
  echo -e "${GREEN}Admin credentials environment variables are set:${NC}"
  echo -e "${YELLOW}$ADMIN_ENV${NC}"
else
  echo -e "${RED}Admin credentials not found in environment variables!${NC}"
  
  # Get credentials from .env file or use defaults
  if [ -f .env ]; then
    ADMIN_USER=$(grep "^ADMIN_USER=" .env | cut -d '=' -f2 || echo "admin")
    ADMIN_PASSWORD=$(grep "^ADMIN_PASSWORD=" .env | cut -d '=' -f2 || echo "FFf3t5h5aJBnTd")
  else
    ADMIN_USER="admin"
    ADMIN_PASSWORD="FFf3t5h5aJBnTd"
  fi
  
  echo -e "${YELLOW}Setting admin credentials to:${NC}"
  echo -e "User: $ADMIN_USER"
  echo -e "Password: $ADMIN_PASSWORD"
  
  # Set environment variables in container
  docker exec admin-panel bash -c "export ADMIN_USER=\"$ADMIN_USER\""
  docker exec admin-panel bash -c "export ADMIN_PASSWORD=\"$ADMIN_PASSWORD\""
  
  # Restart the container to apply environment variables
  echo -e "${YELLOW}Restarting admin-panel container...${NC}"
  docker restart admin-panel
  sleep 5
fi

# Check if admin-panel can connect to postgres
echo -e "\n${YELLOW}Checking database connectivity from admin-panel...${NC}"
POSTGRES_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' postgres)
ADMIN_PANEL_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' admin-panel)

echo -e "${GREEN}PostgreSQL IP: $POSTGRES_IP${NC}"
echo -e "${GREEN}Admin Panel IP: $ADMIN_PANEL_IP${NC}"

# Check network configuration
POSTGRES_NETWORK=$(docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' postgres)
ADMIN_NETWORK=$(docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' admin-panel)

echo -e "${GREEN}PostgreSQL network: $POSTGRES_NETWORK${NC}"
echo -e "${GREEN}Admin Panel network: $ADMIN_NETWORK${NC}"

# Fix session secret if missing
echo -e "\n${YELLOW}Checking for session secret...${NC}"
SESSION_SECRET=$(docker exec admin-panel env | grep SESSION_SECRET)

if [ -z "$SESSION_SECRET" ]; then
  echo -e "${RED}Session secret not found!${NC}"
  
  # Generate a random session secret
  NEW_SECRET=$(openssl rand -base64 32)
  echo -e "${YELLOW}Setting new session secret...${NC}"
  
  # Add to .env file if it exists
  if [ -f .env ]; then
    if grep -q "^SESSION_SECRET=" .env; then
      sed -i "s/^SESSION_SECRET=.*/SESSION_SECRET=$NEW_SECRET/" .env
    else
      echo "SESSION_SECRET=$NEW_SECRET" >> .env
    fi
  fi
  
  # Set environment variable in container
  docker exec admin-panel bash -c "export SESSION_SECRET=\"$NEW_SECRET\""
  
  # Restart the container
  echo -e "${YELLOW}Restarting admin-panel container...${NC}"
  docker restart admin-panel
  sleep 5
else
  echo -e "${GREEN}Session secret is set.${NC}"
fi

# Create or update hardcoded admin credentials if needed
echo -e "\n${YELLOW}Creating hardcoded admin credentials file...${NC}"

ADMIN_CREDS_FILE="/tmp/fix_admin_creds.js"
cat > $ADMIN_CREDS_FILE << EOL
// Script to update or create admin user directly in the database
const { Pool } = require('pg');

// Database connection (using environment variables or defaults)
const pool = new Pool({
  user: process.env.POSTGRES_USER || 'postgres',
  host: process.env.POSTGRES_HOST || 'postgres',
  database: process.env.POSTGRES_DB || 'postgres',
  password: process.env.POSTGRES_PASSWORD,
  port: 5432,
});

async function createAdminUser() {
  try {
    // Check if we can connect to the database
    await pool.query('SELECT NOW()');
    console.log('Database connection successful');
    
    // Check if AdminUsers table exists
    const tableCheck = await pool.query(
      "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'AdminUsers');"
    );
    
    // Create table if it doesn't exist
    if (!tableCheck.rows[0].exists) {
      console.log('Creating AdminUsers table...');
      await pool.query(\`
        CREATE TABLE "AdminUsers" (
          "username" VARCHAR(255) PRIMARY KEY,
          "password" VARCHAR(255) NOT NULL,
          "isActive" BOOLEAN DEFAULT true,
          "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
          "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
      \`);
    }
    
    // Create or update admin user
    console.log('Creating/updating admin user...');
    await pool.query(\`
      INSERT INTO "AdminUsers" ("username", "password", "isActive")
      VALUES ('admin', 'FFf3t5h5aJBnTd', true)
      ON CONFLICT ("username") DO UPDATE 
      SET "password" = 'FFf3t5h5aJBnTd', "isActive" = true, "updatedAt" = CURRENT_TIMESTAMP;
    \`);
    
    console.log('Admin user created/updated successfully!');
  } catch (error) {
    console.error('Error:', error);
  } finally {
    await pool.end();
  }
}

createAdminUser();
EOL

docker cp $ADMIN_CREDS_FILE admin-panel:/tmp/fix_admin_creds.js
echo -e "${YELLOW}Running admin credentials fix script...${NC}"
RESULT=$(docker exec admin-panel node /tmp/fix_admin_creds.js)

echo -e "${GREEN}Result:${NC}"
echo -e "$RESULT"

# Restart the admin-panel container one final time
echo -e "\n${YELLOW}Restarting admin-panel container...${NC}"
docker restart admin-panel
sleep 3

echo -e "\n${GREEN}Admin panel login fix complete!${NC}"
echo -e "${YELLOW}You should now be able to log in with:${NC}"
echo -e "URL: http://136.243.2.232:3001/login"
echo -e "Username: admin"
echo -e "Password: FFf3t5h5aJBnTd"
echo -e "\nIf you still have issues, please check:"
echo -e "1. Docker logs: docker logs admin-panel"
echo -e "2. Database connectivity: docker exec admin-panel ping -c 1 $POSTGRES_IP"
echo -e "3. Session persistence: docker exec admin-panel env | grep SESSION"
