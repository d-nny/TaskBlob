# PowerShell script to initialize all required database tables
# This should be run after all containers are up and running

# Color function (similar to Bash color codes)
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

function Write-Red {
    param([string]$Message)
    Write-ColorOutput -Color Red -Message $Message
}

function Write-Green {
    param([string]$Message)
    Write-ColorOutput -Color Green -Message $Message
}

function Write-Yellow {
    param([string]$Message)
    Write-ColorOutput -Color Yellow -Message $Message
}

Write-Yellow "TaskBlob Database Initialization Tool"
Write-Output "==========================================="

# Load environment variables from .env file
if (Test-Path ".env") {
    Write-Green "Loading environment variables from .env file..."
    Get-Content .env | ForEach-Object {
        if (!$_.StartsWith("#") -and $_.Length -gt 0) {
            $key, $value = $_ -split '=', 2
            [Environment]::SetEnvironmentVariable($key, $value, [EnvironmentVariableTarget]::Process)
        }
    }
} else {
    Write-Red ".env file not found. Please create it with database credentials."
    exit 1
}

# Define the Postgres user and database
$pgUser = if ($env:POSTGRES_USER) { $env:POSTGRES_USER } else { "postgres" }
$pgDB = if ($env:POSTGRES_DB) { $env:POSTGRES_DB } else { "postgres" }
$pgHost = if ($env:POSTGRES_HOST) { $env:POSTGRES_HOST } else { "postgres" }

# Wait for PostgreSQL to be ready
Write-Yellow "`nWaiting for PostgreSQL to be ready..."
$maxRetries = 30
$retryCount = 0
$postgresReady = $false

while ($retryCount -lt $maxRetries -and -not $postgresReady) {
    try {
        $result = docker exec postgres pg_isready -h localhost 2>&1
        if ($result -match "accepting connections") {
            Write-Green "PostgreSQL is ready!"
            $postgresReady = $true
        } else {
            $retryCount++
            Write-Yellow "Waiting for PostgreSQL to be ready... (attempt $retryCount/$maxRetries)"
            Start-Sleep -Seconds 3
        }
    } catch {
        $retryCount++
        Write-Yellow "Waiting for PostgreSQL to be ready... (attempt $retryCount/$maxRetries)"
        Start-Sleep -Seconds 3
    }
}

if (-not $postgresReady) {
    Write-Red "PostgreSQL did not become ready in time. Please check the postgres container."
    exit 1
}

# Define all tables needed for the application
Write-Yellow "`nCreating all required database tables..."

# Create a SQL file with all table definitions
$sqlFile = Join-Path $env:TEMP "create_tables.sql"
$sqlContent = @"
-- DNS Configs table
CREATE TABLE IF NOT EXISTS "DNSConfigs" (
  "domain" VARCHAR(255) PRIMARY KEY,
  "config" JSONB NOT NULL,
  "lastUpdated" TIMESTAMP WITH TIME ZONE,
  "active" BOOLEAN DEFAULT true,
  "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Domain Settings table
CREATE TABLE IF NOT EXISTS "DomainSettings" (
  "domain" VARCHAR(255) PRIMARY KEY,
  "dkimEnabled" BOOLEAN DEFAULT true,
  "spfRecord" VARCHAR(255),
  "dmarcPolicy" VARCHAR(50) DEFAULT 'none',
  "dmarcPercentage" INTEGER DEFAULT 100,
  "dmarcReportEmail" VARCHAR(255),
  "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Cloudflare API table
CREATE TABLE IF NOT EXISTS "CloudflareAPIs" (
  "id" SERIAL PRIMARY KEY,
  "email" VARCHAR(255) NOT NULL,
  "apiKey" VARCHAR(255) NOT NULL,
  "active" BOOLEAN DEFAULT true,
  "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Mail Domain table
CREATE TABLE IF NOT EXISTS "MailDomains" (
  "domain" VARCHAR(255) PRIMARY KEY,
  "description" TEXT,
  "active" BOOLEAN DEFAULT true,
  "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Mail Users table 
CREATE TABLE IF NOT EXISTS "MailUsers" (
  "email" VARCHAR(255) PRIMARY KEY, 
  "domain" VARCHAR(255) NOT NULL,
  "password" VARCHAR(255) NOT NULL,
  "quota" BIGINT DEFAULT 104857600,
  "active" BOOLEAN DEFAULT true,
  "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY ("domain") REFERENCES "MailDomains" ("domain") ON DELETE CASCADE
);

-- Initialize Cloudflare credentials if environment variables are set
INSERT INTO "CloudflareAPIs" ("email", "apiKey", "active")
SELECT '$($env:CLOUDFLARE_EMAIL)', '$($env:CLOUDFLARE_API_KEY)', true
WHERE NOT EXISTS (
    SELECT 1 FROM "CloudflareAPIs" WHERE "email" = '$($env:CLOUDFLARE_EMAIL)'
);
"@

Set-Content -Path $sqlFile -Value $sqlContent

# Copy the SQL file to the postgres container
docker cp $sqlFile postgres:/tmp/create_tables.sql

# Run the SQL file
Write-Yellow "Executing SQL to create all tables..."
$result = docker exec postgres psql -U $pgUser -d $pgDB -f /tmp/create_tables.sql 2>&1

if ($result -match "ERROR") {
    Write-Red "Error creating tables:"
    Write-Red $result
} else {
    Write-Green "All tables created successfully!"
}

# Verify tables were created
Write-Yellow "`nVerifying tables..."
$tables = @("DNSConfigs", "DomainSettings", "CloudflareAPIs", "MailDomains", "MailUsers")

foreach ($table in $tables) {
    $result = docker exec postgres psql -U $pgUser -d $pgDB -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = '$table');" -t 2>&1
    if ($result -match "t") {
        Write-Green "✓ Table $table exists"
    } else {
        Write-Red "✗ Table $table does not exist"
    }
}

# Restart the API containers to recognize the new tables
Write-Yellow "`nRestarting API containers..."
docker restart config-api
Write-Green "config-api container restarted"

try {
    docker restart admin-panel 2>$null
    Write-Green "admin-panel container restarted"
} catch {
    Write-Yellow "admin-panel container not found or could not be restarted"
}

Write-Green "`nDatabase initialization complete!"
Write-Yellow "You can now run your DNS setup scripts."
Write-Output "To check API logs: docker logs config-api"
