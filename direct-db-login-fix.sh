#!/bin/bash
# Direct database login fix for admin panel - doesn't require pg module

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}TaskBlob Admin Panel Direct Database Login Fix${NC}"
echo "==========================================="

# Extract current admin credentials
echo -e "\n${YELLOW}Extracting admin credentials...${NC}"
ADMIN_ENV=$(docker exec admin-panel env | grep ADMIN)

if [[ "$ADMIN_ENV" == *"ADMIN_USER"* ]] && [[ "$ADMIN_ENV" == *"ADMIN_PASSWORD"* ]]; then
  echo -e "${GREEN}Admin credentials found in environment:${NC}"
  echo -e "${YELLOW}$ADMIN_ENV${NC}"
  
  # Extract the credentials for direct login
  ADMIN_USER=$(echo "$ADMIN_ENV" | grep ADMIN_USER | cut -d "=" -f2)
  ADMIN_PASSWORD=$(echo "$ADMIN_ENV" | grep ADMIN_PASSWORD | cut -d "=" -f2)
else
  echo -e "${YELLOW}Using default admin credentials${NC}"
  ADMIN_USER="admin"
  ADMIN_PASSWORD="Py6yBIBIQY8-X1Pc"  # From your logs
fi

echo -e "${GREEN}Using credentials:${NC}"
echo -e "Username: $ADMIN_USER"
echo -e "Password: $ADMIN_PASSWORD"

# Connect directly to PostgreSQL to create admin user
echo -e "\n${YELLOW}Connecting directly to PostgreSQL to create admin user...${NC}"

# Create SQL script
SQL_SCRIPT="/tmp/create_admin.sql"
cat > $SQL_SCRIPT << EOL
-- Check if AdminUsers table exists
DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT FROM information_schema.tables 
        WHERE table_name = 'AdminUsers'
    ) THEN
        CREATE TABLE "AdminUsers" (
            "username" VARCHAR(255) PRIMARY KEY,
            "password" VARCHAR(255) NOT NULL,
            "isActive" BOOLEAN DEFAULT true,
            "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
            "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        RAISE NOTICE 'Created AdminUsers table';
    ELSE
        RAISE NOTICE 'AdminUsers table already exists';
    END IF;
END
\$\$;

-- Insert or update admin user
INSERT INTO "AdminUsers" ("username", "password", "isActive") 
VALUES ('$ADMIN_USER', '$ADMIN_PASSWORD', true)
ON CONFLICT ("username") 
DO UPDATE SET 
    "password" = '$ADMIN_PASSWORD',
    "isActive" = true,
    "updatedAt" = CURRENT_TIMESTAMP;

-- Verify
SELECT * FROM "AdminUsers" WHERE "username" = '$ADMIN_USER';
EOL

# Copy script to postgres container
docker cp $SQL_SCRIPT postgres:/tmp/create_admin.sql

# Execute SQL directly in postgres container
echo -e "${YELLOW}Executing SQL directly in PostgreSQL...${NC}"
DB_USER=${POSTGRES_USER:-postgres}
DB_NAME=${POSTGRES_DB:-postgres}

RESULT=$(docker exec postgres psql -U $DB_USER -d $DB_NAME -f /tmp/create_admin.sql)
echo -e "${GREEN}SQL Result:${NC}"
echo "$RESULT"

# Create views directory and login view if needed
echo -e "\n${YELLOW}Ensuring login view exists...${NC}"
docker exec admin-panel mkdir -p /app/views

LOGIN_EXISTS=$(docker exec admin-panel ls -la /app/views/login.ejs 2>/dev/null)
if [ -z "$LOGIN_EXISTS" ]; then
  echo -e "${YELLOW}Creating login.ejs file...${NC}"
  
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

  # Create the login.ejs file
  echo "$LOGIN_CONTENT" > /tmp/login.ejs
  docker cp /tmp/login.ejs admin-panel:/app/views/login.ejs
  
  echo -e "${GREEN}Created login view!${NC}"
else
  echo -e "${GREEN}Login view exists!${NC}"
fi

# Check server.js for login route
echo -e "\n${YELLOW}Checking if login route is properly defined...${NC}"
LOGIN_ROUTE=$(docker exec admin-panel grep -A 20 "app.get('/login'" /app/server.js 2>/dev/null)

if [ -z "$LOGIN_ROUTE" ]; then
  echo -e "${RED}Login route not found in server.js!${NC}"
  echo -e "${YELLOW}Please check if the admin-panel container has the correct server.js file.${NC}"
  
  # Try to print the server.js content for debugging
  echo -e "${YELLOW}Server.js content:${NC}"
  docker exec admin-panel cat /app/server.js | head -n 50
else
  echo -e "${GREEN}Login route found in server.js:${NC}"
  echo -e "${LOGIN_ROUTE}"
fi

# Fixing root route to properly redirect
echo -e "\n${YELLOW}Ensuring root route redirects to login or dashboard...${NC}"
ROOT_ROUTE=$(docker exec admin-panel grep "app.get('/', " /app/server.js 2>/dev/null)

if [ -z "$ROOT_ROUTE" ]; then
  echo -e "${YELLOW}Root route not found in server.js. Creating temp file with root route...${NC}"
  
  # Create a temp file with the root route
  ROOT_ROUTE_FIX="/tmp/root_route.js"
  cat > $ROOT_ROUTE_FIX << EOL
// Add root route
app.get('/', (req, res) => {
  if (req.session.user) {
    res.redirect('/dashboard');
  } else {
    res.redirect('/login');
  }
});
EOL
  
  echo -e "${YELLOW}You may need to manually add this to server.js:${NC}"
  cat $ROOT_ROUTE_FIX
else
  echo -e "${GREEN}Root route found in server.js:${NC}"
  echo -e "${ROOT_ROUTE}"
fi

# Restart the admin-panel container
echo -e "\n${YELLOW}Restarting admin-panel container...${NC}"
docker restart admin-panel
sleep 3

echo -e "\n${GREEN}Direct database login fix complete!${NC}"
echo -e "${YELLOW}You should now be able to log in with:${NC}"
echo -e "URL: http://136.243.2.232:3001/login"
echo -e "Username: $ADMIN_USER"
echo -e "Password: $ADMIN_PASSWORD"

echo -e "\n${YELLOW}Troubleshooting commands:${NC}"
echo -e "1. Check admin panel logs: docker logs admin-panel"
echo -e "2. Check database connection: docker exec admin-panel ping -c 1 \$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' postgres)"
echo -e "3. Verify database table: docker exec postgres psql -U $DB_USER -d $DB_NAME -c 'SELECT * FROM \"AdminUsers\"'"
