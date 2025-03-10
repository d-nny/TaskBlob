# Configuration-Driven DNS Setup System

This system provides a clean, configuration-driven approach to DNS management for TaskBlob. By completely separating code from configuration, it eliminates Git merge conflicts and provides a more elegant solution.

## Key Benefits

- **Complete Separation of Code and Configuration**: All configuration lives in JSON files, never in scripts
- **Zero Git Conflicts**: No more dealing with stashing or merge conflicts when pulling updates
- **Centralized Configuration**: All DNS settings are defined in a single JSON file
- **Cross-Platform**: Works identically on both Linux and Windows
- **Automatic Fallback**: Seamlessly falls back to direct Cloudflare API if the local API is unavailable

## Components

- `dns-config.json`: Your personal DNS configuration (generated from example file)
- `setup-dns-clean.sh`: Bash implementation that reads configuration from JSON
- `Configure-DNS-Clean.ps1`: PowerShell implementation of the same functionality
- `dns-config.json.example`: Template configuration file

## Getting Started

1. Copy the example configuration:
   ```
   cp dns-config.json.example dns-config.json
   ```

2. Edit the configuration with your specific settings:
   ```
   nano dns-config.json
   ```

3. Run the appropriate script for your platform:

   **Linux/Bash**:
   ```bash
   bash setup-dns-clean.sh
   ```

   **Windows/PowerShell**:
   ```powershell
   .\Configure-DNS-Clean.ps1
   ```

## Configuration File Format

The `dns-config.json` file contains all configuration in a clean, structured format:

```json
{
  "domain": "example.com",
  "primary_ip": "123.45.67.89",
  "mail_ip": "123.45.67.90",
  "api_settings": {
    "url": "http://localhost:3000",
    "use_direct_api": false
  },
  "directories": {
    "dkim": "./dkim"
  },
  "dns_records": {
    "a_records": [...],
    "mx_records": [...],
    "txt_records": [...],
    "srv_records": [...]
  }
}
```

## Script Options

Both scripts support the following options:

### Bash Version (setup-dns-clean.sh)

```bash
bash setup-dns-clean.sh [--config path/to/config.json] [--direct] [--domain example.com]
```

Parameters:
- `--config`: Specify an alternate configuration file (default: dns-config.json)
- `--direct`: Force direct Cloudflare API mode
- `--domain`: Override domain from configuration

### PowerShell Version (Configure-DNS-Clean.ps1)

```powershell
.\Configure-DNS-Clean.ps1 [-ConfigFile path/to/config.json] [-DirectApi] [-Domain example.com]
```

Parameters:
- `-ConfigFile`: Specify an alternate configuration file
- `-DirectApi`: Force direct Cloudflare API mode
- `-Domain`: Override domain from configuration

## How It Works

1. The script loads the JSON configuration file
2. Configuration values can be overridden by command-line parameters
3. Missing values are loaded from the .env file
4. The script generates DKIM keys and DNS records
5. It tries to use the local API, with automatic fallback to direct API mode
6. All DNS records are created/updated according to your configuration

## Why This Approach is Better

1. **Eliminates Git Conflicts**: No more "Your local changes would be overwritten by merge" errors
2. **Cleaner Architecture**: Properly separates code from configuration
3. **More Maintainable**: Changes to DNS records happen in JSON configuration, not script code
4. **Self-Documenting**: JSON structure makes it clear what each record does
5. **Template System**: Uses placeholder substitution for domain, IPs, and DKIM records

## Workflow When Pulling Updates

With this approach, you never have to worry about Git conflicts when pulling updates:

1. Simply `git pull` to get the latest code
2. Your configuration in `dns-config.json` remains untouched
3. Run the updated script, which will use your existing configuration

No stashing or manual merging required!

## Migrating From Previous Approach

If you were using the previous setup-dns.sh script:

1. Check your existing setup-dns.sh for custom changes
2. Move those customizations to dns-config.json
3. Start using the new setup-dns-clean.sh script

## Requirements

- Bash (Linux) or PowerShell (Windows)
- For Linux: jq must be installed (`apt-get install jq`)
- OpenSSL for DKIM key generation
