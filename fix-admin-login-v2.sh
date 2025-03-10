#!/bin/bash
# Script to fix admin panel login issues - v2 with pg module installation

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

# Install pg module in the container
echo -e "\n${YELLOW}Installing PostgreSQL client library in the container...${NC}"
INSTALL_RESULT=$(docker exec admin-panel npm install pg --no-save 2>&1)
if [[ "$INSTALL_RESULT" == *"ERR"* ]]; then
  echo -e "${RED}Error installing pg module:${NC}"
  echo -e "${RED}$INSTALL_RESULT${NC}"
else
  echo -e "${GREEN}Successfully installed pg module${NC}"
fi

# Check environment variables in admin-panel container
echo -e "\n${YELLOW}Checking admin panel environment variables...${NC}"
ADMIN_ENV=$(docker exec admin-panel env | grep ADMIN)

if [[ "$ADMIN_ENV" == *"ADMIN_USER"* ]] && [[ "$ADMIN_ENV" == *"ADMIN_PASSWORD"* ]]; then
  echo -e "${GREEN}Admin credentials environment variables are set:${NC}"
  echo -e "${YELLOW}$ADMIN_ENV${NC}"
  
  # Extract the credentials for direct login
  ADMIN_USER=$(echo "$ADMIN_ENV" | grep ADMIN_USER | cut -d "=" -f2)
  ADMIN_PASSWORD=$(echo "$ADMIN_ENV" | grep ADMIN_PASSWORD | cut -d "=" -f2)
  echo -e "${GREEN}Extracted credentials:${NC}"
  echo -e "Username: $ADMIN_USER"
  echo -e "Password: $ADMIN_PASSWORD"
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

# Check if login.ejs exists and is properly formatted
echo -e "\n${YELLOW}Checking if login view exists...${NC}"
LOGIN_EXISTS=$(docker exec admin-panel ls -la /app/views/login.ejs 2>/dev/null)

if [ -z "$LOGIN_EXISTS" ]; then
  echo -e "${RED}Login view not found! Creating it...${NC}"
  
  # Create login.ejs content
  LOGIN_CONTENT='<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Login - TaskBlob Admin</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@4.6.0/dist/css/bootstrap.min.css">
  <style>
    body {
      background-color: #f8f9fa;
    }
    .login-container {
      max-width: 400px;
      margin: 100px auto;
    }
    .login-card {
      border-radius: 8px;
      box-shadow: 0 4px 8px rgba(0,0,0,0.1);
    }
    .login-logo {
      text-align: center;
      margin-bottom: 24px;
    }
    .login-logo h1 {
      color: #343a40;
    }
  </style>
</head>
<body>
  <div class="container login-container">
    <div class="login-logo">
      <h1>TaskBlob Admin</h1>
      <p class="text-muted">Server Management Panel</p>
    </div>
    <div class="card login-card">
      <div class="card-body">
        <h5 class="card-title text-center mb-4">Login</h5>
        
        <% if (error) { %>
          <div class="alert alert-danger" role="alert">
            <%= error %>
          </div>
        <% } %>
        
        <form method="post" action="/login">
          <div class="form-group">
            <label for="username">Username</label>
            <input type="text" class="form-control" id="username" name="username" required>
          </div>
          <div class="form-group">
            <label for="password">Password</label>
            <input type="password" class="form-control" id="password" name="password" required>
          </div>
          <button type="submit" class="btn btn-primary btn-block">Log In</button>
        </form>
      </div>
    </div>
    <div class="mt-3 text-center">
      <small class="text-muted">
        &copy; <%= new Date().getFullYear() %> TaskBlob. All rights reserved.
      </small>
    </div>
  </div>
  
  <script src="https://code.jquery.com/jquery-3.5.1.slim.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/bootstrap@4.6.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>'

  # Create views directory if it doesn't exist
  docker exec admin-panel mkdir -p /app/views

  # Create the login.ejs file
  echo "$LOGIN_CONTENT" > /tmp/login.ejs
  docker cp /tmp/login.ejs admin-panel:/app/views/login.ejs
  
  echo -e "${GREEN}Created login view!${NC}"
else
  echo -e "${GREEN}Login view exists!${NC}"
fi

# Create direct authentication SQL script
echo -e "\n${YELLOW}Creating direct database authentication script...${NC}"

DB_SCRIPT_FILE="/tmp/fix_admin_direct.js"
cat > $DB_SCRIPT_FILE << EOL
// Script to directly check admin authentication in the database
const { Client } = require('pg');

// Database connection parameters directly
const client = new Client({
  user: 'postgres',
  host: 'postgres',
  database: 'postgres',
  password: '${POSTGRES_PASSWORD:-LTu5xMImiLNrCEHKyUxlYOYD}',
  port: 5432,
});

async function checkAdminAuth() {
  try {
    await client.connect();
    console.log('Connected to PostgreSQL database');
    
    // Check if the AdminUsers table exists
    const tableCheckResult = await client.query(\`
      SELECT EXISTS (
        SELECT FROM information_schema.tables 
        WHERE table_name = 'AdminUsers'
      )
    \`);
    
    const tableExists = tableCheckResult.rows[0].exists;
    console.log('AdminUsers table exists:', tableExists);
    
    if (!tableExists) {
      console.log('Creating AdminUsers table');
      await client.query(\`
        CREATE TABLE "AdminUsers" (
          "username" VARCHAR(255) PRIMARY KEY,
          "password" VARCHAR(255) NOT NULL,
          "isActive" BOOLEAN DEFAULT true,
          "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
          "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
      \`);
    }
    
    // Create or update admin user with plain text password (for simplicity)
    await client.query(\`
      INSERT INTO "AdminUsers" ("username", "password", "isActive") 
      VALUES ('${ADMIN_USER:-admin}', '${ADMIN_PASSWORD:-FFf3t5h5aJBnTd}', true)
      ON CONFLICT ("username") 
      DO UPDATE SET 
        "password" = '${ADMIN_PASSWORD:-FFf3t5h5aJBnTd}',
        "isActive" = true,
        "updatedAt" = CURRENT_TIMESTAMP
    \`);
    
    console.log('Admin user created or updated successfully');
    
    // Verify the user entry
    const userResult = await client.query('SELECT * FROM "AdminUsers" WHERE "username" = $1', ['${ADMIN_USER:-admin}']);
    if (userResult.rows.length > 0) {
      console.log('Admin user found in database:', userResult.rows[0].username);
    } else {
      console.log('WARNING: Admin user not found in database after insert attempt!');
    }
  } catch (err) {
    console.error('Database error:', err);
  } finally {
    await client.end();
  }
}

checkAdminAuth();
EOL

# Copy and run the script in the container
docker cp $DB_SCRIPT_FILE admin-panel:/tmp/fix_admin_direct.js
echo -e "${YELLOW}Running direct database authentication script...${NC}"
RESULT=$(docker exec admin-panel node /tmp/fix_admin_direct.js)

echo -e "${GREEN}Result:${NC}"
echo -e "$RESULT"

# Create a simple self-test script for login route
echo -e "\n${YELLOW}Creating login route test script...${NC}"

TEST_SCRIPT_FILE="/tmp/test_login_route.js"
cat > $TEST_SCRIPT_FILE << EOL
// Simple test to verify login route functionality
const http = require('http');

// Function to test login functionality
function testLogin() {
  console.log('Testing login route...');
  
  // Check if login GET route works
  const options = {
    hostname: 'localhost',
    port: ${PORT:-3001},
    path: '/login',
    method: 'GET'
  };
  
  const req = http.request(options, (res) => {
    console.log('Login route GET status:', res.statusCode);
    let data = '';
    
    res.on('data', (chunk) => {
      data += chunk;
    });
    
    res.on('end', () => {
      const hasLoginForm = data.includes('<form method="post" action="/login">');
      console.log('Login form detected:', hasLoginForm);
    });
  });
  
  req.on('error', (e) => {
    console.error('Login route test error:', e.message);
  });
  
  req.end();
}

// Delay to let server start
setTimeout(testLogin, 500);
EOL

# Copy and run the test script
docker cp $TEST_SCRIPT_FILE admin-panel:/tmp/test_login_route.js
echo -e "${YELLOW}Testing login route...${NC}"
RESULT=$(docker exec admin-panel node /tmp/test_login_route.js)

echo -e "${GREEN}Route Test Result:${NC}"
echo -e "$RESULT"

# Restart the admin-panel container
echo -e "\n${YELLOW}Restarting admin-panel container...${NC}"
docker restart admin-panel
sleep 3

# Provide test curl command to verify login API
echo -e "\n${YELLOW}Generating curl command to test login API...${NC}"
ADMIN_SERVER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' admin-panel)
echo -e "${GREEN}You can test the login API with:${NC}"
echo -e "curl -X POST -d \"username=${ADMIN_USER:-admin}&password=${ADMIN_PASSWORD:-FFf3t5h5aJBnTd}\" -v http://${ADMIN_SERVER_IP}:${PORT:-3001}/login"

echo -e "\n${GREEN}Admin panel login fix complete!${NC}"
echo -e "${YELLOW}You should now be able to log in with:${NC}"
echo -e "URL: http://136.243.2.232:${PORT:-3001}/login"
echo -e "Username: ${ADMIN_USER:-admin}"
echo -e "Password: ${ADMIN_PASSWORD:-FFf3t5h5aJBnTd} (or: ${ADMIN_ENV})"
echo -e "\nIf you still have issues, please check:"
echo -e "1. Docker logs: docker logs admin-panel"
echo -e "2. Database connectivity: docker exec admin-panel ping -c 1 $POSTGRES_IP"
echo -e "3. Try modifying admin-panel/server.js to add console logs for debugging"
