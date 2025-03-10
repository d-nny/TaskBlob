# PowerShell script to diagnose and fix database connection issues

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

Write-Yellow "TaskBlob Database Connection Diagnostic Tool"
Write-Output "==============================================="

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

# Check if database container is running
Write-Yellow "`nChecking if PostgreSQL container is running..."
$postgresContainer = docker ps | Select-String "postgres"
if (!$postgresContainer) {
    Write-Red "PostgreSQL container is not running!"
    Write-Yellow "Checking if container exists but is stopped..."
    
    $stoppedContainer = docker ps -a | Select-String "postgres"
    if ($stoppedContainer) {
        Write-Yellow "Found stopped PostgreSQL container. Attempting to start it..."
        docker start postgres
        Start-Sleep -Seconds 5
        
        # Check if it started successfully
        if (!(docker ps | Select-String "postgres")) {
            Write-Red "Failed to start PostgreSQL container."
        } else {
            Write-Green "Successfully started PostgreSQL container!"
        }
    } else {
        Write-Red "PostgreSQL container does not exist. You may need to run:"
        Write-Output "docker-compose up -d postgres"
    }
} else {
    Write-Green "PostgreSQL container is running."
}

# Get container IP
Write-Yellow "`nChecking PostgreSQL container IP address..."
$postgresIP = docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' postgres
if (!$postgresIP) {
    Write-Red "Could not determine PostgreSQL container IP."
} else {
    Write-Green "PostgreSQL container IP: $postgresIP"
    
    # Check if this IP matches what's in the logs
    Write-Yellow "Verify this IP matches the connection error in your logs"
    Write-Output "(Your logs showed connection attempt to 172.18.0.2)"
}

# Check if config-api can reach the database (might not work in Windows due to WSL)
Write-Yellow "`nChecking if config-api container can reach the database..."
try {
    $result = docker exec config-api ping -c 1 $postgresIP 2>&1
    if ($result -match "100% packet loss" -or $result -match "command not found") {
        Write-Red "Config-api container cannot reach PostgreSQL!"
        Write-Yellow "Checking network configuration..."
        
        # Check if they're on the same network
        $postgresNetwork = docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' postgres
        $apiNetwork = docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' config-api
        
        Write-Output "PostgreSQL network: $postgresNetwork"
        Write-Output "Config-api network: $apiNetwork"
        
        if ($postgresNetwork -ne $apiNetwork) {
            Write-Red "Containers are on different networks!"
            Write-Yellow "You need to ensure both containers are on the same Docker network."
        }
    } else {
        Write-Green "Network connectivity from config-api to PostgreSQL looks good."
    }
} catch {
    Write-Red "Error checking network connectivity: $_"
    Write-Yellow "This may be normal on Windows with Docker Desktop, as ping may not work across containers."
}

# Try connecting directly to verify PostgreSQL is accepting connections
Write-Yellow "`nAttempting to connect to PostgreSQL directly..."
try {
    $postgresRunning = docker exec postgres pg_isready -h localhost 2>&1
    if ($postgresRunning -match "accepting connections") {
        Write-Green "PostgreSQL is up and accepting connections internally."
    } else {
        Write-Red "PostgreSQL is not accepting connections internally: $postgresRunning"
        Write-Yellow "The database may not be fully initialized yet."
    }
} catch {
    Write-Red "Error checking PostgreSQL status: $_"
}

# Check if tables exist (with credentials from .env)
Write-Yellow "`nChecking if DNSConfigs table exists..."
$pgUser = if ($env:POSTGRES_USER) { $env:POSTGRES_USER } else { "postgres" }
$pgDB = if ($env:POSTGRES_DB) { $env:POSTGRES_DB } else { "postgres" }

try {
    $tableCheck = docker exec postgres psql -U $pgUser -d $pgDB -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'DNSConfigs');" -t 2>&1
    if ($tableCheck -match "ERROR") {
        Write-Red "Failed to check table existence: $tableCheck"
    } else {
        if ($tableCheck -match "t") {
            Write-Green "DNSConfigs table exists!"
        } else {
            Write-Red "DNSConfigs table does not exist."
            
            # Create the table manually
            Write-Yellow "Creating DNSConfigs table manually..."
            $createTableCmd = @"
CREATE TABLE IF NOT EXISTS "DNSConfigs" (
  "domain" VARCHAR(255) PRIMARY KEY,
  "config" JSONB NOT NULL,
  "lastUpdated" TIMESTAMP WITH TIME ZONE,
  "active" BOOLEAN DEFAULT true,
  "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL,
  "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL
);
"@
            $createTable = docker exec postgres psql -U $pgUser -d $pgDB -c "$createTableCmd" 2>&1
            
            if ($createTable -match "ERROR") {
                Write-Red "Failed to create table: $createTable"
            } else {
                Write-Green "DNSConfigs table created successfully!"
            }
        }
    }
} catch {
    Write-Red "Error checking/creating table: $_"
}

# Restart the config-api container
Write-Yellow "`nRestarting config-api container..."
docker restart config-api
Write-Green "Config-api container restarted."

Write-Green "`nDiagnostic complete!"
Write-Output "You can check the config-api logs with: docker logs config-api"
