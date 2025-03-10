#!/bin/bash
# This script generates SQL commands with proper passwords from environment variables
# It runs before the SQL initialization script

# Get the passwords from environment variables
POSTGRES_PW="${POSTGRES_PASSWORD:-postgres}"
ROUNDCUBE_PW="${ROUNDCUBE_PASSWORD:-roundcube}"

# Generate the SQL commands
cat > /tmp/create-users.sql << EOF
-- Generated users with secure passwords from environment variables
CREATE USER dbmail WITH PASSWORD '$POSTGRES_PW';
CREATE USER roundcube WITH PASSWORD '$ROUNDCUBE_PW';
CREATE USER config_api WITH PASSWORD '$POSTGRES_PW';
EOF

# Execute the SQL commands
psql -U postgres -d postgres -f /tmp/create-users.sql

# Clean up
rm /tmp/create-users.sql
