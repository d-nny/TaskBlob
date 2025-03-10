#!/bin/bash
# Simple script to fix the root route in admin panel

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}TaskBlob Admin Panel Root Route Fix${NC}"
echo "====================================="

# Verify admin-panel container is running
echo -e "\n${YELLOW}Checking admin-panel container status...${NC}"
ADMIN_CONTAINER=$(docker ps | grep admin-panel)
if [ -z "$ADMIN_CONTAINER" ]; then
  echo -e "${RED}Admin panel container is not running!${NC}"
  exit 1
else
  echo -e "${GREEN}Admin panel container is running.${NC}"
fi

# Check if server.js has a root route
echo -e "\n${YELLOW}Checking if root route exists in server.js...${NC}"
ROOT_ROUTE=$(docker exec admin-panel grep "app.get('/'," /app/server.js 2>/dev/null || docker exec admin-panel grep "app.get('/' " /app/server.js 2>/dev/null)

if [ -z "$ROOT_ROUTE" ]; then
  echo -e "${RED}Root route not found in server.js!${NC}"
  
  # Create the root route patch
  echo -e "${YELLOW}Creating patch for server.js...${NC}"
  
  # Find where login route is defined
  LOGIN_ROUTE_LINE=$(docker exec admin-panel grep -n "app.get('/login" /app/server.js | cut -d ':' -f1)
  
  if [ -z "$LOGIN_ROUTE_LINE" ]; then
    echo -e "${RED}Could not find login route! Can't determine where to insert root route.${NC}"
    
    # Dump server.js for inspection
    echo -e "${YELLOW}Dumping server.js content for manual inspection:${NC}"
    docker exec admin-panel cat /app/server.js
  else
    echo -e "${GREEN}Found login route at line $LOGIN_ROUTE_LINE${NC}"
    
    # Copy server.js to local file
    echo -e "${YELLOW}Copying server.js to make modifications...${NC}"
    docker cp admin-panel:/app/server.js /tmp/server.js
    
    # Insert root route before login route
    ROOT_ROUTE_CODE="// Root route - redirect to dashboard or login\napp.get('/', (req, res) => {\n  if (req.session.user) {\n    res.redirect('/dashboard');\n  } else {\n    res.redirect('/login');\n  }\n});\n\n"
    
    # Create new server.js with root route added
    echo -e "${YELLOW}Adding root route to server.js...${NC}"
    awk -v line="$LOGIN_ROUTE_LINE" -v code="$ROOT_ROUTE_CODE" 'NR==line{print code}1' /tmp/server.js > /tmp/server.js.new
    
    # Backup the original server.js
    echo -e "${YELLOW}Backing up original server.js...${NC}"
    docker exec admin-panel cp /app/server.js /app/server.js.bak
    
    # Copy the modified server.js back to the container
    echo -e "${YELLOW}Copying modified server.js back to container...${NC}"
    docker cp /tmp/server.js.new admin-panel:/app/server.js
    
    # Check if the root route was added successfully
    ROOT_ROUTE_CHECK=$(docker exec admin-panel grep "app.get('/'," /app/server.js 2>/dev/null || docker exec admin-panel grep "app.get('/' " /app/server.js 2>/dev/null)
    
    if [ -z "$ROOT_ROUTE_CHECK" ]; then
      echo -e "${RED}Failed to add root route to server.js!${NC}"
      
      # Try a different approach - add to the beginning of the file
      echo -e "${YELLOW}Trying alternate approach: manually editing server.js...${NC}"
      
      # First few lines of the original file
      HEAD=$(docker exec admin-panel head -n 20 /app/server.js)
      
      # Find where app is defined
      APP_LINE=$(echo "$HEAD" | grep -n "const app = express" | cut -d ':' -f1)
      
      if [ -n "$APP_LINE" ]; then
        echo -e "${GREEN}Found app definition at line $APP_LINE${NC}"
        
        # Find where middleware is done (usually after app.use statements)
        MIDDLEWARE_LINES=$(docker exec admin-panel grep -n "app.use" /app/server.js | tail -1 | cut -d ':' -f1)
        
        if [ -n "$MIDDLEWARE_LINES" ]; then
          echo -e "${GREEN}Found last middleware at line $MIDDLEWARE_LINES${NC}"
          
          # Simple manual approach: Put root route definition in a file
          echo -e "${YELLOW}Creating root route file...${NC}"
          ROOT_ROUTE_FILE="/tmp/root_route.js"
          cat > $ROOT_ROUTE_FILE << EOL
// Root route - redirect to dashboard or login
app.get('/', (req, res) => {
  if (req.session.user) {
    res.redirect('/dashboard');
  } else {
    res.redirect('/login');
  }
});
EOL
          
          # Copy file to container
          echo -e "${YELLOW}Copying root route file to container...${NC}"
          docker cp $ROOT_ROUTE_FILE admin-panel:/app/root_route.js
          
          # Manually explain what to do
          echo -e "${RED}Automatic insertion failed. Please add this code manually after middleware setup in server.js:${NC}"
          cat $ROOT_ROUTE_FILE
        fi
      fi
    else
      echo -e "${GREEN}Root route added successfully:${NC}"
      echo -e "$ROOT_ROUTE_CHECK"
    fi
  fi
else
  echo -e "${GREEN}Root route already exists:${NC}"
  echo -e "$ROOT_ROUTE"
fi

# Create a simple index.html for absolute fallback
echo -e "\n${YELLOW}Creating fallback index.html...${NC}"
FALLBACK_HTML="/tmp/index.html"
cat > $FALLBACK_HTML << EOL
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="0;url=/login">
  <title>Redirecting to Login</title>
</head>
<body>
  <h1>Redirecting to Login Page...</h1>
  <p>If you are not redirected automatically, please <a href="/login">click here</a>.</p>
  <script>window.location.href = '/login';</script>
</body>
</html>
EOL

# Create public directory and copy index.html
echo -e "${YELLOW}Creating public directory and copying fallback index.html...${NC}"
docker exec admin-panel mkdir -p /app/public
docker cp $FALLBACK_HTML admin-panel:/app/public/index.html

# Make sure static files are served
STATIC_FILES=$(docker exec admin-panel grep "express.static" /app/server.js)
if [ -z "$STATIC_FILES" ]; then
  echo -e "${YELLOW}Adding static file middleware...${NC}"
  echo -e "${RED}Static file middleware not found. Please add this line after other middleware in server.js:${NC}"
  echo -e "app.use(express.static(path.join(__dirname, 'public')));"
else
  echo -e "${GREEN}Static file middleware found:${NC}"
  echo -e "$STATIC_FILES"
fi

# Restart the admin-panel container
echo -e "\n${YELLOW}Restarting admin-panel container...${NC}"
docker restart admin-panel
sleep 3

echo -e "\n${GREEN}Root route fix complete!${NC}"
echo -e "${YELLOW}You should now be able to visit:${NC}"
echo -e "http://136.243.2.232:3001/"
echo -e "And be redirected to the login page at:"
echo -e "http://136.243.2.232:3001/login"
