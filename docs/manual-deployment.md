# Manual Deployment Guide

This guide provides instructions for manually deploying TaskBlob by copying files directly to your server rather than using Git.

## Prerequisites

- SSH access to your Hetzner server
- An SFTP client (like FileZilla, WinSCP, or Cyberduck) or SCP for file transfers
- Your server's SSH credentials

## Recommended Copy Procedure

### 1. Prepare Local Files

Before transferring files, ensure your local copy is properly prepared:

1. Remove any `.env` file containing actual credentials
2. Remove any `credentials.enc` files if they exist
3. Create a clean `.env.template` file
4. Run the security check to ensure no sensitive data is present:
   ```bash
   ./security-check.sh
   ```

### 2. Create Deployment Directory on Server

Connect to your server via SSH and create a deployment directory:

```bash
ssh user@your-hetzner-server
mkdir -p /var/server/taskblob
chmod 750 /var/server/taskblob
```

### 3. Transfer Files Using SFTP/SCP

#### Using SCP (Command Line)

From your local machine:

```bash
# Transfer entire directory
scp -r /path/to/local/taskblob/* user@your-hetzner-server:/var/server/taskblob/

# Or use rsync for more control
rsync -avz --exclude='.git' --exclude='.env' /path/to/local/taskblob/ user@your-hetzner-server:/var/server/taskblob/
```

#### Using SFTP Client (GUI)

1. Connect to your server using your SFTP client
2. Navigate to `/var/server/taskblob` on the remote side
3. Select all files from your local TaskBlob directory
4. Upload them to the remote directory
5. Ensure you exclude `.git`, `.env`, and any other sensitive files

### 4. Set Proper Permissions

After transferring files, set the proper permissions via SSH:

```bash
ssh user@your-hetzner-server
cd /var/server/taskblob

# Make scripts executable
chmod +x *.sh
chmod +x bootstrap.js
chmod +x init-credentials.js
chmod +x upgrade-to-master-password.js

# Set ownership (adjust username as needed)
chown -R yourusername:yourusername /var/server/taskblob
```

### 5. Special Considerations for WinRemote

If you're using WinRemote for file access:

```bash
# Create a directory for mail data
mkdir -p /var/server/mail

# Set ownership for WinRemote
chown -R WinRemote:WinRemote /var/server/mail

# Update docker-compose.yml to use this path
# volumes:
#   mail_data:
#     driver: local
#     driver_opts:
#       type: none
#       device: /var/server/mail
#       o: bind
```

## Post-Transfer Tasks

### 1. Initialize Credentials

After transferring files, set up your credentials:

```bash
cd /var/server/taskblob

# Install Node.js dependencies
npm install argon2 dotenv readline fs-extra

# Initialize your credentials
node init-credentials.js
```

### 2. Test Configuration

Verify your setup by running:

```bash
# Test bootstrap
node bootstrap.js

# Verify DNS configuration
node bootstrap.js ./setup-dns.sh --dry-run

# Check firewall configuration
./setup-firewall.sh --check
```

### 3. Start Services

Start the services using the bootstrap script to load credentials:

```bash
node bootstrap.js docker-compose up -d
```

## Common Issues with Manual Transfer

### File Permission Problems

If you encounter permission errors:

```bash
# Find files with incorrect permissions
find /var/server/taskblob -type f -not -perm 644 | grep -v "\.sh$"

# Fix regular file permissions
find /var/server/taskblob -type f -not -name "*.sh" -not -name "bootstrap.js" -not -name "init-credentials.js" -not -name "upgrade-to-master-password.js" -exec chmod 644 {} \;

# Fix script permissions
find /var/server/taskblob -name "*.sh" -o -name "bootstrap.js" -o -name "init-credentials.js" -o -name "upgrade-to-master-password.js" -exec chmod 755 {} \;
```

### Line Ending Issues

If scripts fail with "bad interpreter" errors, fix Windows-style line endings:

```bash
# Install dos2unix if needed
apt-get update && apt-get install -y dos2unix

# Convert line endings
find /var/server/taskblob -name "*.sh" -o -name "bootstrap.js" -o -name "init-credentials.js" -o -name "upgrade-to-master-password.js" -exec dos2unix {} \;
```

### Path Issues in Scripts

If scripts reference incorrect paths, update them:

```bash
# Find instances of hardcoded paths
grep -r "/path/to" /var/server/taskblob

# Update to correct paths
find /var/server/taskblob -type f -name "*.sh" -exec sed -i 's|/path/to/mail|/var/server/mail|g' {} \;
```

## Verification Checklist

After manual deployment, verify:

- [ ] All script files are executable
- [ ] Credentials are properly initialized
- [ ] Docker services start successfully
- [ ] Firewall rules are correctly applied
- [ ] WinRemote user can access required directories
- [ ] DNS configuration points to correct IP addresses
- [ ] Email forwarding works as expected

## Next Steps

After manual deployment is successful, consider setting up proper Git-based deployment for future updates.

1. Initialize a Git repository on the server
2. Add the GitHub repository as a remote
3. Configure proper `.gitignore` to exclude sensitive files
4. Use Git pull for future updates
