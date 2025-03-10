# PowerShell script for direct Cloudflare DNS configuration
# This script bypasses the local API and directly configures Cloudflare DNS records
# Useful when running on development machines where the full Docker stack isn't available

# Load environment variables from .env file
function Load-DotEnv {
    if (Test-Path ".env") {
        Get-Content ".env" | ForEach-Object {
            if ($_ -match "^\s*([^#][^=]+)=(.*)$") {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()
                [Environment]::SetEnvironmentVariable($key, $value, "Process")
                Write-Host "Loaded $key from .env file"
            }
        }
    }
}

# Color output functions
function Write-Green {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Green
}

function Write-Yellow {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Yellow
}

function Write-Red {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Red
}

# Load environment variables
Load-DotEnv

# Check for required variables
if (-not $env:DOMAIN -or -not $env:CLOUDFLARE_EMAIL -or -not $env:CLOUDFLARE_API_KEY) {
    Write-Red "Missing required environment variables. Please make sure .env file contains:"
    Write-Host "DOMAIN=your-domain.com"
    Write-Host "CLOUDFLARE_EMAIL=your-cloudflare-email"
    Write-Host "CLOUDFLARE_API_KEY=your-cloudflare-api-key"
    Write-Host "PRIMARY_IP=your-server-ip"
    Write-Host "MAIL_IP=your-mail-server-ip (optional)"
    exit 1
}

$domain = $env:DOMAIN
$cfEmail = $env:CLOUDFLARE_EMAIL
$cfApiKey = $env:CLOUDFLARE_API_KEY
$primaryIp = $env:PRIMARY_IP
$mailIp = if ($env:MAIL_IP) { $env:MAIL_IP } else { $primaryIp }

Write-Green "Configuring DNS for $domain directly via Cloudflare API"
Write-Host "Primary IP: $primaryIp"
Write-Host "Mail IP: $mailIp"
Write-Host "Cloudflare Email: $cfEmail"
Write-Host "Cloudflare API Key: $($cfApiKey.Substring(0, 5))... (partially hidden for security)"

# Create DNS directory if it doesn't exist
if (-not (Test-Path ".\dns")) {
    New-Item -Path ".\dns" -ItemType Directory | Out-Null
}

# Create DKIM directory if it doesn't exist
if (-not (Test-Path ".\dkim\$domain")) {
    New-Item -Path ".\dkim\$domain" -ItemType Directory -Force | Out-Null
}

# Generate DKIM keys using OpenSSL
Write-Green "Generating DKIM keys..."
try {
    # Check if openssl is available directly
    $opensslTest = openssl version 2>&1
    $opensslAvailable = $?
    
    if ($opensslAvailable) {
        Push-Location ".\dkim\$domain"
        openssl genrsa -out mail.private 2048
        openssl rsa -in mail.private -pubout -out mail.public
        $publicKey = (Get-Content mail.public | Where-Object { $_ -notmatch '^-' }) -join ''
        $dkimRecord = "v=DKIM1; k=rsa; p=$publicKey"
        Set-Content -Path mail.txt -Value $dkimRecord
        Pop-Location
    } else {
        Write-Yellow "OpenSSL not found. Using Docker to generate DKIM keys..."
        docker run --rm -v "${PWD}/dkim:/dkim" -w /dkim alpine/openssl sh -c "
            mkdir -p /dkim/$domain &&
            cd /dkim/$domain &&
            openssl genrsa -out mail.private 2048 &&
            openssl rsa -in mail.private -pubout -out mail.public
            "
        
        # Convert public key to DNS format (if docker was successful)
        if (Test-Path ".\dkim\$domain\mail.public") {
            $publicKey = (Get-Content ".\dkim\$domain\mail.public" | Where-Object { $_ -notmatch '^-' }) -join ''
            $dkimRecord = "v=DKIM1; k=rsa; p=$publicKey"
            Set-Content -Path ".\dkim\$domain\mail.txt" -Value $dkimRecord
        } else {
            Write-Red "Failed to generate DKIM keys."
            Write-Red "This is a critical error for email authentication."
            $dkimRecord = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA" # Placeholder, should be replaced!
            Write-Yellow "Using placeholder DKIM record - this should be replaced before deployment!"
        }
    }
} catch {
    Write-Red "Error generating DKIM keys: $_"
    Write-Yellow "Using placeholder DKIM record - this should be replaced before deployment!"
    $dkimRecord = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA" # Placeholder
}

# Extract domain parts for Cloudflare API
$domainParts = $domain -split '\.'
$rootDomain = "$($domainParts[-2]).$($domainParts[-1])"

# Get Cloudflare Zone ID
Write-Green "Getting Cloudflare Zone ID for $rootDomain..."
$headers = @{
    "X-Auth-Email" = $cfEmail
    "X-Auth-Key" = $cfApiKey
    "Content-Type" = "application/json"
}

$zoneResponse = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones?name=$rootDomain" -Method Get -Headers $headers -ErrorAction SilentlyContinue

if (-not $zoneResponse.success -or $zoneResponse.result.Count -eq 0) {
    Write-Red "Zone not found for domain $rootDomain!"
    Write-Yellow "You need to add this domain to your Cloudflare account first."
    
    $createZone = Read-Host "Do you want to try creating the zone now? (y/N)"
    if ($createZone -eq "y" -or $createZone -eq "Y") {
        Write-Green "Attempting to create zone for $rootDomain..."
        $zoneData = @{
            name = $rootDomain
            jump_start = $true
        } | ConvertTo-Json
        
        try {
            $createResponse = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones" -Method Post -Headers $headers -Body $zoneData -ErrorAction Stop
            if ($createResponse.success) {
                Write-Green "Zone created successfully!"
                $zoneId = $createResponse.result.id
                Write-Yellow "IMPORTANT: You must update your domain's nameservers to point to Cloudflare."
                Write-Host "Nameservers: $($createResponse.result.name_servers -join ', ')"
            } else {
                Write-Red "Failed to create zone:"
                Write-Host ($createResponse.errors | ConvertTo-Json)
                exit 1
            }
        } catch {
            Write-Red "Error creating zone: $_"
            exit 1
        }
    } else {
        Write-Yellow "Zone creation skipped. Please add the domain to Cloudflare manually."
        exit 1
    }
} else {
    $zoneId = $zoneResponse.result[0].id
    Write-Green "Found zone ID: $zoneId"
}

# Save DNS configuration as JSON file for reference
$dnsConfig = @{
    domain = $domain
    config = @{
        records = @{
            a = @(
                @{
                    name = "@"
                    content = $primaryIp
                    proxied = $false
                },
                @{
                    name = "www"
                    content = $primaryIp
                    proxied = $false
                },
                @{
                    name = "mail"
                    content = $mailIp
                    proxied = $false
                },
                @{
                    name = "webmail"
                    content = $primaryIp
                    proxied = $false
                },
                @{
                    name = "admin"
                    content = $primaryIp
                    proxied = $false
                }
            )
            mx = @(
                @{
                    name = "@"
                    content = "mail.$domain"
                    priority = 10
                }
            )
            txt = @(
                @{
                    name = "@"
                    content = "v=spf1 mx ~all"
                },
                @{
                    name = "_dmarc"
                    content = "v=DMARC1; p=none; rua=mailto:admin@$domain"
                },
                @{
                    name = "mail._domainkey"
                    content = $dkimRecord
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
                    target = "mail.$domain"
                },
                @{
                    name = "_submission._tcp"
                    service = "_submission"
                    proto = "_tcp"
                    priority = 0
                    weight = 1
                    port = 587
                    target = "mail.$domain"
                },
                @{
                    name = "_pop3s._tcp"
                    service = "_pop3s"
                    proto = "_tcp"
                    priority = 0
                    weight = 1
                    port = 995
                    target = "mail.$domain"
                }
            )
        }
    }
}

$dnsConfigJson = $dnsConfig | ConvertTo-Json -Depth 10
Set-Content -Path ".\dns\${domain}_config.json" -Value $dnsConfigJson
Write-Green "DNS configuration saved to .\dns\${domain}_config.json"

# Get existing DNS records
Write-Green "Getting existing DNS records..."
try {
    $existingRecords = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records" -Method Get -Headers $headers
    if ($existingRecords.success) {
        Write-Host "Found $($existingRecords.result.Count) existing DNS records"
    } else {
        Write-Yellow "Failed to get existing DNS records. Will attempt to create records anyway."
        $existingRecords = $null
    }
} catch {
    Write-Yellow "Error getting existing DNS records: $_"
    $existingRecords = $null
}

# Function to find existing record
function Get-ExistingRecord {
    param(
        [string]$Type,
        [string]$Name
    )
    
    if ($null -eq $existingRecords -or -not $existingRecords.success) {
        return $null
    }
    
    # For root domain (@)
    if ($Name -eq "@") {
        $fullName = $rootDomain
    } else {
        $fullName = "$Name.$rootDomain"
    }
    
    return $existingRecords.result | Where-Object { $_.type -eq $Type -and $_.name -eq $fullName }
}

# Create or update A records
Write-Green "Creating/Updating A records..."
$aRecords = @(
    @{ name = "@"; content = $primaryIp },
    @{ name = "www"; content = $primaryIp },
    @{ name = "mail"; content = $mailIp },
    @{ name = "webmail"; content = $primaryIp },
    @{ name = "admin"; content = $primaryIp }
)

foreach ($record in $aRecords) {
    $recordData = @{
        type = "A"
        name = $record.name
        content = $record.content
        ttl = 1
        proxied = $false
    } | ConvertTo-Json
    
    # Check if record exists
    $existingRecord = Get-ExistingRecord -Type "A" -Name $record.name
    
    try {
        if ($existingRecord) {
            # Update existing record
            $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records/$($existingRecord.id)" -Method Put -Headers $headers -Body $recordData -ErrorAction SilentlyContinue
            if ($response.success) {
                Write-Host "Updated A record: $($record.name) -> $($record.content)"
            } else {
                Write-Yellow "Failed to update A record $($record.name): $($response.errors | ConvertTo-Json)"
            }
        } else {
            # Create new record
            $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records" -Method Post -Headers $headers -Body $recordData -ErrorAction SilentlyContinue
            if ($response.success) {
                Write-Host "Created A record: $($record.name) -> $($record.content)"
            } else {
                Write-Yellow "Failed to create A record $($record.name): $($response.errors | ConvertTo-Json)"
            }
        }
    } catch {
        Write-Yellow "Error processing A record $($record.name): $_"
    }
}

# Create or update MX record
Write-Green "Creating/Updating MX record..."
$mxData = @{
    type = "MX"
    name = "@"
    content = "mail.$domain"
    priority = 10
    ttl = 1
} | ConvertTo-Json

try {
    # Check if MX record exists
    $existingMX = Get-ExistingRecord -Type "MX" -Name "@"
    
    if ($existingMX) {
        # Update existing record
        $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records/$($existingMX.id)" -Method Put -Headers $headers -Body $mxData -ErrorAction SilentlyContinue
        if ($response.success) {
            Write-Host "Updated MX record: mail.$domain"
        } else {
            Write-Yellow "Failed to update MX record: $($response.errors | ConvertTo-Json)"
        }
    } else {
        # Create new record
        $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records" -Method Post -Headers $headers -Body $mxData -ErrorAction SilentlyContinue
        if ($response.success) {
            Write-Host "Created MX record: mail.$domain"
        } else {
            Write-Yellow "Failed to create MX record: $($response.errors | ConvertTo-Json)"
        }
    }
} catch {
    Write-Yellow "Error processing MX record: $_"
}

# Create or update TXT records
Write-Green "Creating/Updating TXT records (SPF, DMARC, DKIM)..."
$txtRecords = @(
    @{ name = "@"; content = "v=spf1 mx ~all" },
    @{ name = "_dmarc"; content = "v=DMARC1; p=none; rua=mailto:admin@$domain" },
    @{ name = "mail._domainkey"; content = $dkimRecord }
)

foreach ($record in $txtRecords) {
    $recordData = @{
        type = "TXT"
        name = $record.name
        content = $record.content
        ttl = 1
    } | ConvertTo-Json
    
    try {
        # Check if TXT record exists
        $existingTXT = Get-ExistingRecord -Type "TXT" -Name $record.name
        
        if ($existingTXT) {
            # Update existing record
            $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records/$($existingTXT.id)" -Method Put -Headers $headers -Body $recordData -ErrorAction SilentlyContinue
            if ($response.success) {
                Write-Host "Updated TXT record: $($record.name)"
            } else {
                Write-Yellow "Failed to update TXT record $($record.name): $($response.errors | ConvertTo-Json)"
            }
        } else {
            # Create new record
            $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records" -Method Post -Headers $headers -Body $recordData -ErrorAction SilentlyContinue
            if ($response.success) {
                Write-Host "Created TXT record: $($record.name)"
            } else {
                Write-Yellow "Failed to create TXT record $($record.name): $($response.errors | ConvertTo-Json)"
            }
        }
    } catch {
        Write-Yellow "Error processing TXT record $($record.name): $_"
    }
}

# Create or update SRV records
Write-Green "Creating/Updating SRV records..."
$srvRecords = @(
    @{ service = "_imaps"; proto = "_tcp"; port = 993 },
    @{ service = "_submission"; proto = "_tcp"; port = 587 },
    @{ service = "_pop3s"; proto = "_tcp"; port = 995 }
)

foreach ($record in $srvRecords) {
    $recordName = "$($record.service).$($record.proto)"
    $recordData = @{
        type = "SRV"
        name = $recordName
        data = @{
            service = $record.service
            proto = $record.proto
            name = $domain
            priority = 0
            weight = 1
            port = $record.port
            target = "mail.$domain"
        }
        ttl = 1
    } | ConvertTo-Json
    
    try {
        # SRV records are a bit more complex to match
        $fullSrvName = "$recordName.$rootDomain"
        $existingSRV = $existingRecords.result | Where-Object { $_.type -eq "SRV" -and $_.name -eq $fullSrvName }
        
        if ($existingSRV) {
            # Update existing record
            $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records/$($existingSRV.id)" -Method Put -Headers $headers -Body $recordData -ErrorAction SilentlyContinue
            if ($response.success) {
                Write-Host "Updated SRV record: $recordName"
            } else {
                Write-Yellow "Failed to update SRV record $recordName`: $($response.errors | ConvertTo-Json)"
            }
        } else {
            # Create new record
            $response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records" -Method Post -Headers $headers -Body $recordData -ErrorAction SilentlyContinue
            if ($response.success) {
                Write-Host "Created SRV record: $recordName"
            } else {
                Write-Yellow "Failed to create SRV record $recordName`: $($response.errors | ConvertTo-Json)"
            }
        }
    } catch {
        Write-Yellow "Error processing SRV record $recordName`: $_"
    }
}

Write-Green "DNS configuration complete!"
Write-Green "DKIM keys have been generated and saved to .\dkim\$domain\"
Write-Green "DNS records have been created in Cloudflare for $domain"
Write-Green ""
Write-Green "On your Linux server, you will need to:"
Write-Green "1. Copy DKIM keys to the appropriate location:"
Write-Host "   mkdir -p /var/server/dkim/$domain"
Write-Host "   cp ./dkim/$domain/mail.private /var/server/dkim/$domain/"
Write-Host "   cp ./dkim/$domain/mail.txt /var/server/dkim/$domain/"
Write-Green ""
Write-Green "2. Run the complete setup script once deployed:"
Write-Host "   ./setup-dns.sh"
Write-Green ""
Write-Yellow "Note: DNS changes may take some time to propagate (typically 15-30 minutes, but can take up to 24-48 hours)"
