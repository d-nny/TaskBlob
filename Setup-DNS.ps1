# PowerShell Script for automated DNS, DKIM, and SSL setup
# This script interacts with the config-api service to manage DNS records via Cloudflare

# Color definitions (for PowerShell 5.1+)
function Write-ColorOutput($ForegroundColor) {
    # Save the current colors
    $previousForegroundColor = $host.UI.RawUI.ForegroundColor
    
    # Set the new foreground color
    $host.UI.RawUI.ForegroundColor = $ForegroundColor
    
    # Write the next command's output in the new color
    if ($args) {
        Write-Output $args
    }
    else {
        # Read from the pipeline
        $input | Write-Output
    }
    
    # Restore the original colors
    $host.UI.RawUI.ForegroundColor = $previousForegroundColor
}

# Variables
$DKIM_DIR = ".\dkim"
$API_URL = "http://localhost:3000"

# Load environment variables if .env file exists
if (Test-Path ".env") {
    Get-Content ".env" | ForEach-Object {
        if ($_ -match "^\s*([^#][^=]+)=(.*)$") {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            Set-Item -Path "env:$key" -Value $value
        }
    }
}

# Verify required env variables
if (-not $env:DOMAIN) {
    Write-ColorOutput Red "ERROR: DOMAIN must be set in .env file or environment"
    Write-Output "Create a .env file with DOMAIN=example.com"
    exit 1
}

# Set domain and IP variables from environment or prompt
$DOMAIN = $env:DOMAIN

# Ask for domain if not set
if (-not $DOMAIN) {
    $DOMAIN = Read-Host -Prompt "Enter your domain name"
    if (-not $DOMAIN) {
        Write-ColorOutput Red "Domain name is required."
        exit 1
    }
}

$PRIMARY_IP = $env:PRIMARY_IP
$MAIL_IP = $env:MAIL_IP
$IPV6_PREFIX = $env:IPV6_PREFIX

# Ask for IP addresses if not set
if (-not $PRIMARY_IP) {
    $PRIMARY_IP = Read-Host -Prompt "Enter your primary IP address"
    if (-not $PRIMARY_IP) {
        Write-ColorOutput Red "Primary IP address is required."
        exit 1
    }
}

if (-not $MAIL_IP) {
    $MAIL_IP = Read-Host -Prompt "Enter your mail server IP address (or press Enter to use primary IP)"
    if (-not $MAIL_IP) {
        $MAIL_IP = $PRIMARY_IP
    }
}

if (-not $IPV6_PREFIX) {
    $IPV6_PREFIX = Read-Host -Prompt "Enter your IPv6 prefix (optional)"
}

if (-not $env:CLOUDFLARE_EMAIL -or -not $env:CLOUDFLARE_API_KEY) {
    Write-ColorOutput Red "ERROR: CLOUDFLARE_EMAIL and CLOUDFLARE_API_KEY must be set in .env file or environment"
    Write-Output "Create a .env file with:"
    Write-Output "CLOUDFLARE_EMAIL=your_email@example.com"
    Write-Output "CLOUDFLARE_API_KEY=your_global_api_key"
    exit 1
}

# Create directory structure
Write-ColorOutput Green "Creating directory structure..."
New-Item -Path "$DKIM_DIR\$DOMAIN" -ItemType Directory -Force

# 1. Generate DKIM keys (using Docker to run OpenSSL)
Write-ColorOutput Green "Generating DKIM keys for $DOMAIN..."
docker run --rm -v "${PWD}/dkim:/dkim" -w /dkim alpine/openssl sh -c "
mkdir -p /dkim/$DOMAIN &&
cd /dkim/$DOMAIN &&
openssl genrsa -out mail.private 2048 &&
openssl rsa -in mail.private -pubout -out mail.public
"

# Convert public key to DNS format
$PUBLIC_KEY = (Get-Content ".\dkim\$DOMAIN\mail.public" | Where-Object { $_ -notmatch '^-' }) -join ''
$DKIM_RECORD = "v=DKIM1; k=rsa; p=$PUBLIC_KEY"
Set-Content -Path ".\dkim\$DOMAIN\mail.txt" -Value $DKIM_RECORD

# 2. Create DNS configuration object
Write-ColorOutput Green "Creating DNS configuration for $DOMAIN..."
$DNS_CONFIG = @{
    domain = $DOMAIN
    config = @{
        records = @{
            a = @(
                @{
                    name = "@"
                    content = $PRIMARY_IP
                    proxied = $false
                },
                @{
                    name = "www"
                    content = $PRIMARY_IP
                    proxied = $false
                },
                @{
                    name = "mail"
                    content = $MAIL_IP
                    proxied = $false
                },
                @{
                    name = "webmail"
                    content = $PRIMARY_IP
                    proxied = $false
                },
                @{
                    name = "admin"
                    content = $PRIMARY_IP
                    proxied = $false
                }
            )
            mx = @(
                @{
                    name = "@"
                    content = "mail.$DOMAIN"
                    priority = 10
                }
            )
            txt = @(
                @{
                    name = "@"
                    content = "v=spf1 mx ~all"
                    proxied = $false
                },
                @{
                    name = "_dmarc"
                    content = "v=DMARC1; p=none; rua=mailto:admin@$DOMAIN"
                    proxied = $false
                },
                @{
                    name = "mail._domainkey"
                    content = $DKIM_RECORD
                    proxied = $false
                }
            )
            srv = @(
                @{
                    name = "_imaps._tcp"
                    service = "_imaps"
                    proto = "_tcp"
                    priority = 0
                    weight = 1
                    port = 993
                    target = "mail.$DOMAIN"
                },
                @{
                    name = "_submission._tcp"
                    service = "_submission"
                    proto = "_tcp"
                    priority = 0
                    weight = 1
                    port = 587
                    target = "mail.$DOMAIN"
                },
                @{
                    name = "_pop3s._tcp"
                    service = "_pop3s"
                    proto = "_tcp"
                    priority = 0
                    weight = 1
                    port = 995
                    target = "mail.$DOMAIN"
                }
            )
        }
    }
}

# 3. Push DNS configuration to API for Cloudflare integration
Write-ColorOutput Green "Pushing DNS configuration to Cloudflare via API..."
try {
    $DNS_CONFIG_JSON = $DNS_CONFIG | ConvertTo-Json -Depth 10
    $DNS_RESPONSE = Invoke-RestMethod -Uri "$API_URL/api/dns" -Method Post -Body $DNS_CONFIG_JSON -ContentType "application/json" -ErrorAction Stop
    Write-ColorOutput Green "DNS configuration created: $($DNS_RESPONSE.domain)"
}
catch {
    Write-ColorOutput Red "Error creating DNS configuration: $_"
    exit 1
}

# 4. Update DNS records in Cloudflare
Write-ColorOutput Green "Updating DNS records in Cloudflare..."
try {
    $UPDATE_RESPONSE = Invoke-RestMethod -Uri "$API_URL/api/dns/$DOMAIN/update" -Method Post -ErrorAction Stop
    Write-ColorOutput Green "DNS records updated:"
    Write-Output "Created: $($UPDATE_RESPONSE.results.created.Length) records"
    Write-Output "Updated: $($UPDATE_RESPONSE.results.updated.Length) records"
    if ($UPDATE_RESPONSE.results.errors.Length -gt 0) {
        Write-ColorOutput Yellow "Errors: $($UPDATE_RESPONSE.results.errors.Length) records"
    }
}
catch {
    Write-ColorOutput Red "Error updating DNS records: $_"
    exit 1
}

# 5. Wait for DNS propagation
Write-ColorOutput Yellow "Waiting 60 seconds for DNS propagation..."
Start-Sleep -Seconds 60

# 6. Register the domain for mail use
Write-ColorOutput Green "Registering domain for mail use..."
try {
    $MAIL_DOMAIN_BODY = @{
        domain = $DOMAIN
        description = "Mail domain for $DOMAIN"
    } | ConvertTo-Json
    
    $MAIL_DOMAIN_RESPONSE = Invoke-RestMethod -Uri "$API_URL/api/mail/domains" -Method Post -Body $MAIL_DOMAIN_BODY -ContentType "application/json" -ErrorAction Stop
    Write-ColorOutput Green "Mail domain registered: $($MAIL_DOMAIN_RESPONSE.domain)"
}
catch {
    Write-ColorOutput Red "Error registering mail domain: $_"
}

# 7. Create admin user
Write-ColorOutput Green "Creating admin mail user..."
try {
    $ADMIN_USER_BODY = @{
        email = "admin@$DOMAIN"
        domain = $DOMAIN
        password = "changeme!"
    } | ConvertTo-Json
    
    $ADMIN_USER_RESPONSE = Invoke-RestMethod -Uri "$API_URL/api/mail/users" -Method Post -Body $ADMIN_USER_BODY -ContentType "application/json" -ErrorAction Stop
    Write-ColorOutput Green "Admin user created: $($ADMIN_USER_RESPONSE.email)"
}
catch {
    Write-ColorOutput Red "Error creating admin user: $_"
}

# 8. Generate SSL certificate using DNS validation
Write-ColorOutput Green "Generating SSL certificate for mail.$DOMAIN..."
try {
    $SSL_BODY = @{
        email = "admin@$DOMAIN"
        subdomains = @("mail", "webmail")
    } | ConvertTo-Json
    
    $SSL_RESPONSE = Invoke-RestMethod -Uri "$API_URL/api/ssl/$DOMAIN/generate" -Method Post -Body $SSL_BODY -ContentType "application/json" -ErrorAction Stop
    Write-ColorOutput Green "SSL certificate script created: $($SSL_RESPONSE.scriptPath)"
    Write-ColorOutput Yellow "NOTE: The SSL certificate script must be run on the Linux server with root privileges."
    Write-Output "Run this command on your server:"
    Write-Output "sudo $($SSL_RESPONSE.scriptPath)"
}
catch {
    Write-ColorOutput Red "Error generating SSL certificate: $_"
}

# 9. Display Docker commands to copy DKIM keys
Write-ColorOutput Green "Docker commands to run on your server for DKIM keys:"
Write-Output "mkdir -p /var/server/dkim/$DOMAIN"
Write-Output "cp ./dkim/$DOMAIN/mail.private /var/server/dkim/$DOMAIN/"
Write-Output "cp ./dkim/$DOMAIN/mail.txt /var/server/dkim/$DOMAIN/"
Write-Output ""
Write-Output "mkdir -p ./dkim/$DOMAIN"
Write-Output "cp ./dkim/$DOMAIN/mail.private ./dkim/$DOMAIN/"
Write-Output "cp ./dkim/$DOMAIN/mail.txt ./dkim/$DOMAIN/"

# 10. Display Docker commands to restart services
Write-ColorOutput Green "Docker commands to restart services on your server:"
Write-Output "docker-compose restart mailserver"
Write-Output "docker-compose restart nginx"

# Summary
Write-ColorOutput Green "=== SETUP COMPLETE ==="
Write-ColorOutput Green "Your mail server is now configured with:"
Write-Output "  - DNS records in Cloudflare"
Write-Output "  - DKIM keys for email authentication"
Write-Output "  - SSL certificates for secure connections"
Write-Output "  - Default admin account: admin@$DOMAIN (password: changeme!)"
Write-Output ""
Write-ColorOutput Yellow "IMPORTANT: Please change the default admin password immediately!"
Write-Output "You can do this through the webmail interface at https://webmail.$DOMAIN"
Write-Output ""
Write-ColorOutput Green "To verify your setup:"
Write-Output "1. Check DNS records: dig +short MX $DOMAIN"
Write-Output "2. Test SMTP connection: telnet mail.$DOMAIN 25"
Write-Output "3. Test IMAP connection: openssl s_client -connect mail.$DOMAIN:993"
Write-Output "4. Access webmail at: https://webmail.$DOMAIN"
