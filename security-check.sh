#!/bin/bash
# Security check script to scan for sensitive info before pushing to git

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== SECURITY CHECK FOR GIT PUSH ===${NC}"
echo -e "Scanning repository for potentially sensitive information..."

# Define patterns to search for
PATTERNS=(
    # IP addresses
    "[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}"
    # Domain names (excluding example.com)
    "\b(?!example\.com)[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}\b"
    # API keys and tokens
    "[\"']?[Aa][Pp][Ii][_-]?[Kk][Ee][Yy][\"']?\s*[:=]\s*[\"'][A-Za-z0-9_/\.\-]{20,}[\"']"
    "TOKEN[\"']?\s*[:=]\s*[\"'][A-Za-z0-9_/\.\-]{20,}[\"']"
    # Credentials
    "password\s*[:=]\s*[\"'][^\"']{3,}[\"']"
    "passwd\s*[:=]\s*[\"'][^\"']{3,}[\"']"
    "credentials\s*[:=]"
    "PASSWORD\s*[:=]\s*[\"'][^\"']{3,}[\"']"
    # AWS
    "AKIA[0-9A-Z]{16}"
    # Email addresses (excluding example.com)
    "\b[A-Za-z0-9._%+-]+@(?!example\.com)[A-Za-z0-9.-]+\.[A-Za-z]{2,6}\b"
    # SSH private keys
    "BEGIN\s+(?:RSA|DSA|EC|OPENSSH)\s+PRIVATE\s+KEY"
    # Hardcoded secrets
    "CHANGEME!"
    "changeme"
    "default_password"
    "secret\s*[:=]\s*[\"'][^\"']{3,}[\"']"
)

# Files and directories to exclude
EXCLUDE=(
    "*.md"
    "node_modules/"
    ".git/"
    ".gitignore"
    "*.template"
    "security-check.sh"
    "SECURITY.md"
)

# Build exclude args
EXCLUDE_ARGS=""
for pattern in "${EXCLUDE[@]}"; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude='$pattern'"
done

# Check for common issues
echo -e "\n${YELLOW}Checking for potential issues:${NC}"

ISSUE_COUNT=0
WARNINGS=()

for pattern in "${PATTERNS[@]}"; do
    # Execute grep with the exclude arguments
    result=$(eval "grep -r -I --include='*.sh' --include='*.js' --include='*.json' --include='*.yml' --include='*.yaml' --include='*.ps1' --include='*.ejs' $EXCLUDE_ARGS '$pattern' . || true")
    
    if [ -n "$result" ]; then
        ISSUE_COUNT=$((ISSUE_COUNT+1))
        WARNINGS+=("$result")
        echo -e "${YELLOW}WARNING:${NC} Found potential sensitive information matching pattern: ${YELLOW}$pattern${NC}"
    fi
done

# Check for .env file
if [ -f .env ]; then
    ISSUE_COUNT=$((ISSUE_COUNT+1))
    echo -e "${RED}CRITICAL:${NC} Found .env file that may contain sensitive credentials."
    echo -e "         This file should not be committed to git."
    echo -e "         Make sure it's listed in your .gitignore."
fi

# Check .gitignore
if [ ! -f .gitignore ]; then
    ISSUE_COUNT=$((ISSUE_COUNT+1))
    echo -e "${RED}CRITICAL:${NC} No .gitignore file found."
else
    # Check if .env is ignored
    if ! grep -q "^\.env$" .gitignore; then
        ISSUE_COUNT=$((ISSUE_COUNT+1))
        echo -e "${RED}CRITICAL:${NC} The .env file is not listed in .gitignore."
    fi
    
    # Check if ssl and dkim directories are ignored
    if ! grep -q "^/ssl/" .gitignore; then
        ISSUE_COUNT=$((ISSUE_COUNT+1))
        echo -e "${RED}CRITICAL:${NC} The /ssl/ directory is not listed in .gitignore."
    fi
    
    if ! grep -q "^/dkim/" .gitignore; then
        ISSUE_COUNT=$((ISSUE_COUNT+1))
        echo -e "${RED}CRITICAL:${NC} The /dkim/ directory is not listed in .gitignore."
    fi
fi

# Summary
if [ $ISSUE_COUNT -eq 0 ]; then
    echo -e "\n${GREEN}✓ No obvious security issues found.${NC}"
    echo -e "  The repository appears safe to push to GitHub."
else
    echo -e "\n${RED}✗ Found $ISSUE_COUNT potential security issues!${NC}"
    echo -e "  Please fix these issues before pushing to a public repository."
    echo -e "  Check the warnings above for more details."
    
    # Show some of the warnings
    if [ ${#WARNINGS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Here are some examples of the findings:${NC}"
        for i in {0..2}; do
            if [ $i -lt ${#WARNINGS[@]} ]; then
                echo -e "  - ${WARNINGS[$i]}"
            fi
        done
        
        if [ ${#WARNINGS[@]} -gt 3 ]; then
            echo -e "  ... and ${#WARNINGS[@] - 3} more."
        fi
    fi
    
    echo -e "\n${YELLOW}Recommendations:${NC}"
    echo -e "  1. Move sensitive information to environment variables"
    echo -e "  2. Make sure .env is in your .gitignore"
    echo -e "  3. Replace real IPs and domains with placeholders"
    echo -e "  4. Remove hardcoded credentials"
    
    exit 1
fi

exit 0
