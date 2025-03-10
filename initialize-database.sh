#!/bin/bash
# Comprehensive script to initialize all required database tables
# This should be run after all containers are up and running

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}TaskBlob Database Initialization Tool${NC}"
echo "==========================================="

# Load environment variables from .env file
if [ -f .env ]; then
  echo -e "${GREEN}Loading environment variables from .env file...${NC}"
  export $(grep -v '^#' .env | xargs)
else
  echo -e "${RED}.env file not found. Please create it with database credentials.${NC}"
  exit 1
fi

# Define the Postgres user and database
PG_USER=${POSTGRES_USER:-postgres}
PG_DB=${POSTGRES_DB:-postgres}
PG_HOST=${POSTGRES_HOST:-postgres}

# Wait for PostgreSQL to be ready
echo -e "\n${YELLOW}Waiting for PostgreSQL to be ready...${NC}"
MAX_RETRIES=30
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if docker exec postgres pg_isready -h localhost > /dev/null 2>&1; then
    echo -e "${GREEN}PostgreSQL is ready!${NC}"
    break
  else
    RETRY_COUNT=$((RETRY_COUNT+1))
    echo -e "${YELLOW}Waiting for PostgreSQL to be ready... (attempt $RETRY_COUNT/$MAX_RETRIES)${NC}"
    sleep 3
  fi
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
  echo -e "${RED}PostgreSQL did not become ready in time. Please check the postgres container.${NC}"
  exit 1
fi

# Define all tables needed for the application
echo -e "\n${YELLOW}Creating all required database tables...${NC}"

# Create a SQL file with all table definitions
SQL_FILE="/tmp/create_tables.sql"
cat > $SQL_FILE << EOL
-- DNS Configs table
CREATE TABLE IF NOT EXISTS "DNSConfigs" (
  "domain" VARCHAR(255) PRIMARY KEY,
  "config" JSONB NOT NULL,
  "lastUpdated" TIMESTAMP WITH TIME ZONE,
  "active" BOOLEAN DEFAULT true,
  "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Domain Settings table
CREATE TABLE IF NOT EXISTS "DomainSettings" (
  "domain" VARCHAR(255) PRIMARY KEY,
  "dkimEnabled" BOOLEAN DEFAULT true,
  "spfRecord" VARCHAR(255),
  "dmarcPolicy" VARCHAR(50) DEFAULT 'none',
  "dmarcPercentage" INTEGER DEFAULT 100,
  "dmarcReportEmail" VARCHAR(255),
  "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Cloudflare API table
CREATE TABLE IF NOT EXISTS "CloudflareAPIs" (
  "id" SERIAL PRIMARY KEY,
  "email" VARCHAR(255) NOT NULL,
  "apiKey" VARCHAR(255) NOT NULL,
  "active" BOOLEAN DEFAULT true,
  "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Mail Domain table
CREATE TABLE IF NOT EXISTS "MailDomains" (
  "domain" VARCHAR(255) PRIMARY KEY,
  "description" TEXT,
  "active" BOOLEAN DEFAULT true,
  "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Mail Users table 
CREATE TABLE IF NOT EXISTS "MailUsers" (
  "email" VARCHAR(255) PRIMARY KEY, 
  "domain" VARCHAR(255) NOT NULL,
  "password" VARCHAR(255) NOT NULL,
  "quota" BIGINT DEFAULT 104857600,
  "active" BOOLEAN DEFAULT true,
  "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY ("domain") REFERENCES "MailDomains" ("domain") ON DELETE CASCADE
);

-- Initialize Cloudflare credentials if environment variables are set
INSERT INTO "CloudflareAPIs" ("email", "apiKey", "active")
SELECT '${CLOUDFLARE_EMAIL}', '${CLOUDFLARE_API_KEY}', true
WHERE NOT EXISTS (
    SELECT 1 FROM "CloudflareAPIs" WHERE "email" = '${CLOUDFLARE_EMAIL}'
);
EOL

# Copy the SQL file to the postgres container
docker cp $SQL_FILE postgres:/tmp/create_tables.sql

# Run the SQL file
echo -e "${YELLOW}Executing SQL to create all tables...${NC}"
RESULT=$(docker exec postgres psql -U $PG_USER -d $PG_DB -f /tmp/create_tables.sql 2>&1)

if [[ "$RESULT" == *"ERROR"* ]]; then
  echo -e "${RED}Error creating tables:${NC}"
  echo -e "${RED}$RESULT${NC}"
else
  echo -e "${GREEN}All tables created successfully!${NC}"
fi

# Verify tables were created
echo -e "\n${YELLOW}Verifying tables...${NC}"
TABLES=("DNSConfigs" "DomainSettings" "CloudflareAPIs" "MailDomains" "MailUsers")

for TABLE in "${TABLES[@]}"; do
  RESULT=$(docker exec postgres psql -U $PG_USER -d $PG_DB -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = '$TABLE');" -t)
  if [[ $RESULT == *"t"* ]]; then
    echo -e "${GREEN}✓ Table $TABLE exists${NC}"
  else
    echo -e "${RED}✗ Table $TABLE does not exist${NC}"
  fi
done

# Restart the API containers to recognize the new tables
echo -e "\n${YELLOW}Restarting API containers...${NC}"
docker restart config-api
echo -e "${GREEN}config-api container restarted${NC}"

docker restart admin-panel 2>/dev/null || echo -e "${YELLOW}admin-panel container not found or could not be restarted${NC}"

echo -e "\n${GREEN}Database initialization complete!${NC}"
echo -e "${YELLOW}You can now run your DNS setup scripts.${NC}"
echo -e "To check API logs: docker logs config-api"
