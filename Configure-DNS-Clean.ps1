# PowerShell script for DNS configuration using external JSON configuration
# This approach completely separates code from configuration

# Color definitions (for PowerShell)
function Write-ColorOutput {
    param(
        [string]$Color,
        [string]$Message
    )
    $originalColor = $host.UI.RawUI.ForegroundColor
    $host.UI.RawUI.ForegroundColor = $Color
    Write-Output $Message
    $host.UI.RawUI.ForegroundColor = $originalColor
}

function Write-Green {
    param([string]$Message)
    Write-ColorOutput -Color Green -Message $Message
}

function Write-Yellow {
    param([string]$Message)
    Write-ColorOutput -Color Yellow -Message $Message
}

function Write-Red {
    param([string]$Message)
    Write-ColorOutput -Color Red -Message $Message
}

# Parse command line arguments
param(
    [string]$ConfigFile = "dns-config.json",
    [string]$Domain,
    [switch]$DirectApi
)

# Check if config file exists
if (-not (Test-Path $ConfigFile)) {
    # Check if example config exists
    if (Test-Path "${ConfigFile}.example") {
        Write-Yellow "Config file $ConfigFile not found, but example exists."
        Write-Yellow "Creating a copy from example... (you should edit this with your settings)"
        Copy-Item "${ConfigFile}.example" $ConfigFile
    } else {
        Write-Red "Error: Configuration file $ConfigFile not found"
        Write-Output "Please create a config file or specify one with -ConfigFile"
        exit 1
    }
}

Write-Green "Using configuration from $ConfigFile"

# Load configuration from JSON
try {
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
} catch {
    Write-Red "Error parsing JSON configuration: $_"
    exit 1
}

# Extract configuration
$configDomain = $config.domain
$primaryIp = $config.primary_ip
$mailIp = $config.mail_ip
$apiUrl = if ($config.api_settings.url) { $config.api_settings.url } else { "http://localhost:3000" }
$useDirectApi = if ($DirectApi) { $true } else { $config.api_settings.use_direct_api }
$dkimDir = if ($config.directories.dkim) { $config.directories.dkim } else { "./dkim" }

# Override with command line parameters if provided
if ($Domain) { 
    $configDomain = $Domain 
}

# If mail IP is not set, use primary IP
if (-not $mailIp) {
    $mailIp = $primaryIp
}

# Load environment variables from .env file as fallback
if (Test-Path ".env") {
    # Only load values that aren't already set
    $envContent = Get-Content ".env"
    foreach ($line in $envContent) {
        if ($line -match "^([^=]+)=(.*)$") {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            
            switch ($key) {
                "DOMAIN" { 
                    if (-not $configDomain) { $configDomain = $value } 
                }
                "PRIMARY_IP" { 
                    if (-not $primaryIp) { $primaryIp = $value } 
                }
                "MAIL_IP" { 
                    if (-not $mailIp) { $mailIp = $value } 
                }
                "CLOUDFLARE_EMAIL" { 
                    $cloudflareEmail = $value 
                }
                "CLOUDFLARE_API_KEY" { 
                    $cloudflareApiKey = $value 
                }
            }
        }
    }
    Write-Green "Loaded fallback values from .env file"
}

# Check required parameters
if (-not $configDomain) {
    Write-Red "Error: Domain is required"
    Write-Output "Specify domain in config file, .env file, or as parameter"
    exit 1
}

if (-not $primaryIp) {
    Write-Yellow "Primary IP not set, prompting..."
    $primaryIp = Read-Host "Enter your primary IP address"
    if (-not $primaryIp) {
        Write-Red "Primary IP address is required."
        exit 1
    }
    
    # Save this to config for future runs
    $config.primary_ip = $primaryIp
    $config | ConvertTo-Json -Depth 10 | Set-Content $ConfigFile
}

if (-not $mailIp) {
    # Use PRIMARY_IP as fallback
    $mailIp = $primaryIp
    Write-Yellow "Mail IP not set, using Primary IP: $mailIp"
    
    # Save this to config for future runs
    $config.mail_ip = $mailIp
    $config | ConvertTo-Json -Depth 10 | Set-Content $ConfigFile
}

# Check Cloudflare credentials
if (-not $cloudflareEmail -or -not $cloudflareApiKey) {
    Write-Red "ERROR: CLOUDFLARE_EMAIL and CLOUDFLARE_API_KEY must be set in .env file"
    Write-Output "Create a .env file with:"
    Write-Output "CLOUDFLARE_EMAIL=your_email@example.com"
    Write-Output "CLOUDFLARE_API_KEY=your_global_api_key"
    exit 1
}

# Show configuration
Write-Green "Using the following configuration:"
Write-Output "  DOMAIN: $configDomain"
Write-Output "  PRIMARY_IP: $primaryIp"
Write-Output "  MAIL_IP: $mailIp"
Write-Output "  CLOUDFLARE_EMAIL: $cloudflareEmail"
Write-Output "  CLOUDFLARE_API_KEY: $($cloudflareApiKey.Substring(0, 5))... (partially hidden)"
Write-Output "  API_URL: $apiUrl"
Write-Output "  USING DIRECT API: $useDirectApi"

# Function to check API status
function Test-ApiStatus {
    try {
        $response = Invoke-WebRequest -Uri "$apiUrl/api/status" -Method Get -UseBasicParsing -ErrorAction SilentlyContinue
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

# Verify API is accessible (skip if using direct API)
if (-not $useDirectApi) {
    Write-Green "Verifying API connectivity..."
    $maxRetries = 5
    $retryCount = 0
    $apiAccessible = $false
    
    while ($retryCount -lt $maxRetries -and -not $apiAccessible) {
        if (Test-ApiStatus) {
            Write-Green "API is accessible!"
            $apiAccessible = $true
        } else {
            Write-Yellow "API not available yet. Retrying in 10 seconds... (attempt $($retryCount+1)/$maxRetries)"
            Start-Sleep -Seconds 10
            $retryCount++
        }
    }

    if (-not $apiAccessible) {
        Write-Yellow "WARNING: API is not accessible after $maxRetries attempts."
        Write-Yellow "Switching to direct Cloudflare API mode"
        $useDirectApi = $true
    }
}

# Create directory structure
$dkimDomainPath = Join-Path $dkimDir $configDomain
if (-not (Test-Path $dkimDomainPath)) {
    New-Item -Path $dkimDomainPath -ItemType Directory -Force | Out-Null
}

# 1. Generate DKIM keys
Write-Green "Generating DKIM keys for $configDomain..."

try {
    # Check if openssl is available directly
    $opensslTest = openssl version 2>&1
    $opensslAvailable = $?
    
    if ($opensslAvailable) {
        Push-Location $dkimDomainPath
        openssl genrsa -out mail.private 2048
        openssl rsa -in mail.private -pubout -out mail.public
        $publicKey = (Get-Content mail.public | Where-Object { $_ -notmatch '^-' }) -join ''
        $dkimRecord = "v=DKIM1; k=rsa; p=$publicKey"
        Set-Content -Path mail.txt -Value $dkimRecord
        Pop-Location
    } else {
        Write-Yellow "OpenSSL not found. Using Docker to generate DKIM keys..."
        docker run --rm -v "${PWD}/dkim:/dkim" -w /dkim alpine/openssl sh -c "
            mkdir -p /dkim/$configDomain &&
            cd /dkim/$configDomain &&
            openssl genrsa -out mail.private 2048 &&
            openssl rsa -in mail.private -pubout -out mail.public
            "
        
        # Convert public key to DNS format (if docker was successful)
        if (Test-Path (Join-Path $dkimDomainPath "mail.public")) {
            $publicKey = (Get-Content (Join-Path $dkimDomainPath "mail.public") | Where-Object { $_ -notmatch '^-' }) -join ''
            $dkimRecord = "v=DKIM1; k=rsa; p=$publicKey"
            Set-Content -Path (Join-Path $dkimDomainPath "mail.txt") -Value $dkimRecord
        } else {
            Write-Red "Failed to generate DKIM keys."
            Write-Red "This is a critical error for email authentication."
            $dkimRecord = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA" # Placeholder
            Write-Yellow "Using placeholder DKIM record - this should be replaced before deployment!"
        }
    }
} catch {
    Write-Red "Error generating DKIM keys: $_"
    Write-Yellow "Using placeholder DKIM record - this should be replaced before deployment!"
    $dkimRecord = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA" # Placeholder
}

# Generate DNS config with templates filled in
Write-Green "Creating DNS configuration for $configDomain..."

# Replace placeholders in the JSON configuration 
$dnsRecordsJson = $config.dns_records | ConvertTo-Json -Depth 10 -Compress
$dnsRecordsJson = $dnsRecordsJson.Replace('#DOMAIN#', $configDomain)
$dnsRecordsJson = $dnsRecordsJson.Replace('#PRIMARY_IP#', $primaryIp)
$dnsRecordsJson = $dnsRecordsJson.Replace('#MAIL_IP#', $mailIp)
$dnsRecordsJson = $dnsRecordsJson.Replace('#DKIM_RECORD#', $dkimRecord)
$dnsRecords = $dnsRecordsJson | ConvertFrom-Json

# Create the full DNS config object
$fullDnsConfig = @{
    domain = $configDomain
    config = @{
        records = $dnsRecords
    }
}

# Create DNS directory if it doesn't exist
if (-not (Test-Path ".\dns")) {
    New-Item -Path ".\dns" -ItemType Directory -Force | Out-Null
}

# Save DNS config to file for debugging purposes
Write-Green "Saving DNS configuration to dns/$($configDomain)_config.json..."
$fullDnsConfig | ConvertTo-Json -Depth 10 | Set-Content ".\dns\$($configDomain)_config.json"

# Extract domain parts for Cloudflare API
$domainParts = $configDomain -split '\.'
$rootDomain = "$($domainParts[-2]).$($domainParts[-1])"

# Set headers for all Cloudflare API requests
$headers = @{
    "X-Auth-Email" = $cloudflareEmail
    "X-Auth-Key" = $cloudflareApiKey
    "Content-Type" = "application/json"
}

# Direct API approach
if ($useDirectApi) {
    Write-Green "Using direct Cloudflare API..."
    
    Write-Green "Getting zone ID for $rootDomain..."
    try {
        $zoneResponse = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones?name=$rootDomain" -Method Get -Headers $headers -ErrorAction SilentlyContinue
        
        if (-not $zoneResponse.success -or $zoneResponse.result.Count -eq 0) {
            Write-Red "Zone not found for domain $rootDomain!"
            Write-Yellow "You need to add this domain to your Cloudflare account first."
            Write-Yellow "Would you like to try creating the zone now? (y/N)"
            $createZone = Read-Host
            
            if ($createZone -eq "y" -or $createZone -eq "Y") {
                Write-Green "Attempting to create zone for $rootDomain..."
                $zoneData = @{
                    name = $rootDomain
                    jump_start = $true
                } | ConvertTo-Json
                
                try {
                    $createResponse = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones" -Method Post -Headers $headers -Body $zoneData
                    if ($createResponse.success) {
                        Write-Green "Zone created successfully!"
                        $zoneId = $createResponse.result.id
                        Write-Yellow "IMPORTANT: You must update your domain's nameservers to point to Cloudflare."
                        Write-Output "Nameservers: $($createResponse.result.name_servers -join ', ')"
                    } else {
                        Write-Red "Failed to create zone:"
                        Write-Output ($createResponse.errors | ConvertTo-Json)
                        return
                    }
                } catch {
                    Write-Red "Error creating zone: $_"
                    return
                }
            } else {
                Write-Yellow "Zone creation skipped. Please add the domain to Cloudflare manually."
                return
            }
        } else {
            $zoneId = $zoneResponse.result[0].id
            Write-Green "Found zone ID: $zoneId"
        }
        
        # Process A records
        Write-Green "Processing A records..."
        foreach ($record in $dnsRecords.a_records) {
            $recordName = $record.name
            $content = $record.content
            $proxied = $record.proxied
            
            if (!$proxied) { $proxied = $false }
            
            if ($recordName -eq "@") {
                $fullRecordName = $rootDomain
                $recordName = "@"
            } else {
                $fullRecordName = "$recordName.$rootDomain"
            }
            
            Write-Output "Creating/Updating A record: $fullRecordName -> $content"
            $cfRecord = @{
                type = "A"
                name = $recordName
                content = $content
                ttl = 1
                proxied = $proxied
            } | ConvertTo-Json
            
            try {
                $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records" -Method Post -Headers $headers -Body $cfRecord -ErrorAction SilentlyContinue
                if ($response.success) {
                    Write-Output "  Success!"
                } else {
                    Write-Yellow "  Failed: $($response.errors | ConvertTo-Json)"
                }
            } catch {
                Write-Yellow "  Error: $_"
            }
        }
        
        # Process MX records
        Write-Green "Processing MX records..."
        foreach ($record in $dnsRecords.mx_records) {
            $recordName = $record.name
            $content = $record.content
            $priority = if ($record.priority) { $record.priority } else { 10 }
            
            if ($recordName -eq "@") {
                $fullRecordName = $rootDomain
                $recordName = "@"
            } else {
                $fullRecordName = "$recordName.$rootDomain"
            }
            
            Write-Output "Creating/Updating MX record: $fullRecordName -> $content (priority: $priority)"
            $cfRecord = @{
                type = "MX"
                name = $recordName
                content = $content
                priority = $priority
                ttl = 1
            } | ConvertTo-Json
            
            try {
                $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records" -Method Post -Headers $headers -Body $cfRecord -ErrorAction SilentlyContinue
                if ($response.success) {
                    Write-Output "  Success!"
                } else {
                    Write-Yellow "  Failed: $($response.errors | ConvertTo-Json)"
                }
            } catch {
                Write-Yellow "  Error: $_"
            }
        }
        
        # Process TXT records
        Write-Green "Processing TXT records..."
        foreach ($record in $dnsRecords.txt_records) {
            $recordName = $record.name
            $content = $record.content
            
            if ($recordName -eq "@") {
                $fullRecordName = $rootDomain
                $recordName = "@"
            } else {
                $fullRecordName = "$recordName.$rootDomain"
            }
            
            Write-Output "Creating/Updating TXT record: $fullRecordName"
            $cfRecord = @{
                type = "TXT"
                name = $recordName
                content = $content
                ttl = 1
            } | ConvertTo-Json
            
            try {
                $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records" -Method Post -Headers $headers -Body $cfRecord -ErrorAction SilentlyContinue
                if ($response.success) {
                    Write-Output "  Success!"
                } else {
                    Write-Yellow "  Failed: $($response.errors | ConvertTo-Json)"
                }
            } catch {
                Write-Yellow "  Error: $_"
            }
        }
        
        # Process SRV records
        Write-Green "Processing SRV records..."
        foreach ($record in $dnsRecords.srv_records) {
            $recordName = $record.name
            $service = $record.service
            $proto = $record.proto
            $priority = if ($record.priority) { $record.priority } else { 0 }
            $weight = if ($record.weight) { $record.weight } else { 1 }
            $port = $record.port
            $target = $record.target
            
            Write-Output "Creating/Updating SRV record: $recordName"
            $cfRecord = @{
                type = "SRV"
                name = $recordName
                data = @{
                    service = $service
                    proto = $proto
                    name = $configDomain
                    priority = $priority
                    weight = $weight
                    port = $port
                    target = $target
                }
                ttl = 1
            } | ConvertTo-Json
            
            try {
                $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records" -Method Post -Headers $headers -Body $cfRecord -ErrorAction SilentlyContinue
                if ($response.success) {
                    Write-Output "  Success!"
                } else {
                    Write-Yellow "  Failed: $($response.errors | ConvertTo-Json)"
                }
            } catch {
                Write-Yellow "  Error: $_"
            }
        }
        
        Write-Green "DNS records created directly via Cloudflare API"
    } 
    catch {
        Write-Red "Error working with Cloudflare API: $_"
    }
}
else {
    # API approach
    Write-Green "Pushing DNS configuration to API..."
    Write-Output "API URL: $apiUrl/api/dns"
    Write-Output "Making API request..."

    try {
        # First try using the API
        $fullDnsConfigJson = $fullDnsConfig | ConvertTo-Json -Depth 10 -Compress
        $dnsResponse = Invoke-RestMethod -Uri "$apiUrl/api/dns" -Method Post -Headers $headers -Body $fullDnsConfigJson -ContentType "application/json"
        Write-Green "Successfully created DNS configuration via API"
        
        # Update DNS records in Cloudflare through API
        Write-Green "Updating DNS records in Cloudflare..."
        $updateResponse = Invoke-RestMethod -Uri "$apiUrl/api/dns/$configDomain/update" -Method Post -Headers $headers
        Write-Green "DNS records updated successfully via API"
        
        # Wait for DNS propagation
        Write-Yellow "Waiting 60 seconds for DNS propagation..."
        Start-Sleep -Seconds 60
        
        # Register the domain for mail use
        Write-Green "Registering domain for mail use..."
        $mailDomainBody = @{
            domain = $configDomain
            description = "Mail domain for $configDomain"
        } | ConvertTo-Json
        
        try {
            $mailDomainResponse = Invoke-RestMethod -Uri "$apiUrl/api/mail/domains" -Method Post -Body $mailDomainBody -ContentType "application/json"
            Write-Green "Mail domain registered successfully"
        } catch {
            Write-Red "Error registering mail domain: $_"
            Write-Yellow "This is non-critical, continuing with the setup..."
        }
        
        # Create admin user
        Write-Green "Creating admin mail user..."
        # Use password from environment or a randomly generated one
        $adminPassword = [System.Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes(9))
        
        $adminUserBody = @{
            email = "admin@$configDomain"
            domain = $configDomain
            password = $adminPassword
        } | ConvertTo-Json
        
        try {
            $adminUserResponse = Invoke-RestMethod -Uri "$apiUrl/api/mail/users" -Method Post -Body $adminUserBody -ContentType "application/json"
            Write-Green "Admin user created successfully"
            
            # Save password
            Set-Content -Path "admin_credentials.txt" -Value "Admin password for admin@$configDomain`: $adminPassword"
            Write-Yellow "A random password was generated for admin@$configDomain."
            Write-Yellow "It has been saved to admin_credentials.txt. Please store it securely and delete this file."
        } catch {
            Write-Red "Error creating admin user: $_"
            Write-Yellow "This is non-critical, continuing with the setup..."
        }
        
        # Generate SSL certificate
        Write-Green "Generating SSL certificate for mail.$configDomain..."
        $sslBody = @{
            email = "admin@$configDomain"
            subdomains = @("mail", "webmail")
        } | ConvertTo-Json
        
        try {
            $sslResponse = Invoke-RestMethod -Uri "$apiUrl/api/ssl/$configDomain/generate" -Method Post -Body $sslBody -ContentType "application/json"
            Write-Green "SSL certificate generation initiated:"
            Write-Yellow "NOTE: The SSL certificate script must be run on the Linux server with root privileges."
            Write-Output "Run this command on your server:"
            Write-Output "sudo $($sslResponse.scriptPath)"
        } catch {
            Write-Red "Error generating SSL certificate: $_"
            Write-Yellow "SSL certificate generation failed, you may need to run this manually later."
        }
    }
    catch {
        Write-Red "API approach failed: $_"
        Write-Yellow "Consider using the -DirectApi switch to use direct Cloudflare API"
    }
}

# Save DKIM keys for server deployment
Write-Green "DNS configuration complete!"
Write-Green "DKIM keys have been generated and saved to $dkimDomainPath"
Write-Green "On your Linux server, you will need to:"
Write-Output "  mkdir -p /var/server/dkim/$configDomain"
Write-Output "  cp ./dkim/$configDomain/mail.private /var/server/dkim/$configDomain/"
Write-Output "  cp ./dkim/$configDomain/mail.txt /var/server/dkim/$configDomain/"

Write-Green ""
Write-Green "=== SETUP COMPLETE ==="
Write-Green "Your mail server is now configured with:"
Write-Output "  - DNS records in Cloudflare"
Write-Output "  - DKIM keys for email authentication"
if (-not $useDirectApi) {
    Write-Output "  - SSL certificates for secure connections"
    Write-Output "  - Default admin account: admin@$configDomain"
    if (Test-Path "admin_credentials.txt") {
        Write-Yellow "IMPORTANT: The admin password was saved to admin_credentials.txt"
        Write-Yellow "Please store it securely and delete this file after noting the password."
    }
}

Write-Green ""
Write-Green "To verify your setup:"
Write-Output "1. Check DNS records: dig +short MX $configDomain"
Write-Output "2. Test SMTP connection: telnet mail.$configDomain 25"
Write-Output "3. Test IMAP connection: openssl s_client -connect mail.$configDomain:993"
Write-Output "4. Access webmail at: https://webmail.$configDomain"

Write-Yellow ""
Write-Yellow "If you encountered any errors during this process, check:"
Write-Output "1. Docker logs: docker logs config-api"
Write-Output "2. Your .env file to ensure all required variables are set correctly"
Write-Output "3. Cloudflare dashboard to confirm DNS records were created"
Write-Output "4. Run individual failed steps manually if needed"
