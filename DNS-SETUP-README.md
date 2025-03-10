# DNS Setup System Documentation

## Template-Based System for DNS Configuration

This directory contains a template-based system for DNS configuration that allows you to pull updates from the Git repository without encountering merge conflicts with your local customizations.

## How It Works

Instead of directly modifying `setup-dns.sh`, this system uses:

1. `setup-dns.template.sh` - The template file tracked by Git
2. `settings.local.sh` - Your local settings (not tracked by Git)
3. `update-dns-script.sh` - A script to update your working copy from the template

This allows you to:
- Pull updates from the repository without conflicts
- Maintain your own customizations separate from the core script
- Quickly revert to the standard implementation if needed

## Files Overview

- `setup-dns.template.sh`: The main script template tracked by Git
- `settings.local.sh.example`: Example settings file showing available customizations
- `settings.local.sh`: Your actual settings file (create this from the example)
- `update-dns-script.sh`: Script to update your working copy of setup-dns.sh

## Getting Started

1. Create your local settings file:
   ```bash
   cp settings.local.sh.example settings.local.sh
   ```

2. Edit your settings file with your specific configuration:
   ```bash
   nano settings.local.sh
   ```

3. Run the update script to generate your working copy:
   ```bash
   bash update-dns-script.sh
   ```

## Workflow for Git Updates

When pulling updates from the repository:

1. Stash any changes to tracked files:
   ```bash
   git stash
   ```

2. Pull the latest updates:
   ```bash
   git pull
   ```

3. Update your working copy of the DNS setup script:
   ```bash
   bash update-dns-script.sh
   ```

4. Restore any stashed changes if needed:
   ```bash
   git stash pop
   ```

## Customization Options

In your `settings.local.sh` file, you can override any of these settings:

- `DOMAIN_OVERRIDE`: Override the domain from .env or command line
- `PRIMARY_IP_OVERRIDE`: Override the primary IP address
- `MAIL_IP_OVERRIDE`: Override the mail server IP address
- `API_URL_OVERRIDE`: Change the API URL (default: http://localhost:3000)
- `USE_DIRECT_API_OVERRIDE`: Force direct Cloudflare API usage (true/false)
- `DKIM_DIR_OVERRIDE`: Change the DKIM keys directory

## Direct vs. API Mode

The script can operate in two modes:

1. **API Mode** (default): Uses the local config-api container to manage DNS
   - Requires Docker containers to be running
   - Provides more features (mail user creation, SSL certs)

2. **Direct Mode**: Communicates directly with Cloudflare's API
   - Works even when Docker isn't running
   - Great for development machines or initial setup
   - Set `USE_DIRECT_API_OVERRIDE=true` in settings.local.sh to force

The script will automatically fall back to Direct Mode if the API isn't accessible.

## Windows Support

For Windows development environments, use the PowerShell script:

```powershell
.\Configure-DNS-Direct.ps1
```

This script reads from the same `.env` file but works directly on Windows without requiring bash.
