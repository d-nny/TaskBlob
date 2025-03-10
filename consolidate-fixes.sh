#!/bin/bash
# Script to consolidate all fixes into the original build and clean up individual fix scripts

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}TaskBlob Admin Panel Fix Consolidation${NC}"
echo "======================================="

# Check if the updated server.js exists
if [ ! -f "config-admin/server.js.updated" ]; then
  echo -e "${RED}Updated server.js file not found!${NC}"
  exit 1
fi

# Backup original server.js
echo -e "\n${YELLOW}Backing up original server.js...${NC}"
if [ -f "config-admin/server.js" ]; then
  cp config-admin/server.js config-admin/server.js.bak
  echo -e "${GREEN}Original server.js backed up to server.js.bak${NC}"
else
  echo -e "${RED}Original server.js not found!${NC}"
  exit 1
fi

# Replace server.js with updated version
echo -e "\n${YELLOW}Replacing server.js with consolidated version...${NC}"
cp config-admin/server.js.updated config-admin/server.js
echo -e "${GREEN}Server.js updated with consolidated version${NC}"

# Create a public directory if it doesn't exist
mkdir -p config-admin/public

# Create fallback index.html
echo -e "\n${YELLOW}Creating fallback index.html in public directory...${NC}"
cat > config-admin/public/index.html << EOL
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
echo -e "${GREEN}Fallback index.html created${NC}"

# Add pg module to package.json if it doesn't exist
echo -e "\n${YELLOW}Ensuring pg module is in package.json...${NC}"
if [ -f "config-admin/package.json" ]; then
  # Check if pg is already in dependencies
  if grep -q '"pg":' config-admin/package.json; then
    echo -e "${GREEN}pg module already exists in package.json${NC}"
  else
    # Use sed to add pg to dependencies
    sed -i 's/"dependencies": {/"dependencies": {\n    "pg": "^8.7.1",/' config-admin/package.json
    echo -e "${GREEN}Added pg module to package.json${NC}"
  fi
else
  echo -e "${RED}package.json not found!${NC}"
fi

# Create list of fix scripts to be removed
echo -e "\n${YELLOW}Identifying fix scripts to be removed...${NC}"
FIX_SCRIPTS=(
  "fix-root-route.sh"
  "fix-admin-login.sh"
  "fix-admin-login-v2.sh"
  "direct-db-login-fix.sh"
  "Fix-AdminLogin.ps1"
)

# Create backup directory for removed scripts
BACKUP_DIR="fix-scripts-backup"
mkdir -p $BACKUP_DIR

# Move fix scripts to backup directory
echo -e "\n${YELLOW}Moving fix scripts to backup directory...${NC}"
for script in "${FIX_SCRIPTS[@]}"; do
  if [ -f "$script" ]; then
    mv "$script" "$BACKUP_DIR/"
    echo -e "${GREEN}Moved $script to backup${NC}"
  else
    echo -e "${YELLOW}Script $script not found, skipping${NC}"
  fi
done

# Remove the updated file now that we've copied it
echo -e "\n${YELLOW}Removing temporary updated server.js file...${NC}"
rm -f config-admin/server.js.updated
echo -e "${GREEN}Removed config-admin/server.js.updated${NC}"

# Update docker-compose.yml to ensure admin-panel has access to pg module
echo -e "\n${YELLOW}Checking docker-compose.yml for admin-panel configuration...${NC}"
if [ -f "docker-compose.yml" ]; then
  echo -e "${GREEN}docker-compose.yml found, you may need to rebuild the admin-panel container${NC}"
  echo -e "${YELLOW}Run 'docker-compose up -d --build admin-panel' to apply changes${NC}"
else
  echo -e "${RED}docker-compose.yml not found!${NC}"
fi

echo -e "\n${GREEN}Consolidation complete!${NC}"
echo -e "${YELLOW}The following changes have been made:${NC}"
echo -e "1. Server.js has been updated with all fixes"
echo -e "2. A fallback index.html has been created"
echo -e "3. Fix scripts have been moved to $BACKUP_DIR"
echo -e "4. Package.json has been updated to include pg module"
echo -e "\n${YELLOW}Next steps:${NC}"
echo -e "1. Rebuild and restart the admin-panel container with:"
echo -e "   docker-compose up -d --build admin-panel"
echo -e "2. Verify the admin panel is working correctly"
echo -e "3. Once verified, you can safely remove the $BACKUP_DIR directory"
