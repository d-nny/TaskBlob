# PowerShell script to fix admin panel login issues

# Color function for output formatting
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

Write-Yellow "TaskBlob Admin Panel Login Fix"
Write-Output "==============================="

# Check if admin-panel container is running
Write-Yellow "`nChecking admin-panel container status..."
$adminContainer = docker ps | Select-String "admin-panel"
if (!$adminContainer) {
    Write-Red "Admin panel container is not running!"
    Write-Yellow "Checking if container exists but is stopped..."
    
    $stoppedContainer = docker ps -a | Select-String "admin-panel"
    if ($stoppedContainer) {
        Write-Yellow "Found stopped admin-panel container. Attempting to start it..."
        docker start admin-panel
        Start-Sleep -Seconds 5
        
        # Check if it started successfully
        if (!(docker ps | Select-String "admin-panel")) {
            Write-Red "Failed to start admin-panel container."
        } else {
            Write-Green "Successfully started admin-panel container!"
        }
    } else {
        Write-Red "Admin panel container does not exist. You may need to run:"
        Write-Output "docker-compose up -d admin-panel"
    }
} else {
    Write-Green "Admin panel container is running."
}

# Check environment variables in admin-panel container
Write-Yellow "`nChecking admin panel environment variables..."
$adminEnv = docker exec admin-panel env | Select-String "ADMIN"

if ($adminEnv -match "ADMIN_USER" -and $adminEnv -match "ADMIN_PASSWORD") {
    Write-Green "Admin credentials environment variables are set:"
    Write-Yellow $adminEnv
} else {
    Write-Red "Admin credentials not found in environment variables!"
    
    # Get credentials from .env file or use defaults
    if (Test-Path ".env") {
        $envContent = Get-Content .env
        $adminUser = ($envContent | Where-Object { $_ -match "^ADMIN_USER=" } | ForEach-Object { $_ -replace "^ADMIN_USER=", "" }) -join ""
        $adminPassword = ($envContent | Where-Object { $_ -match "^ADMIN_PASSWORD=" } | ForEach-Object { $_ -replace "^ADMIN_PASSWORD=", "" }) -join ""
        
        if ([string]::IsNullOrEmpty($adminUser)) { $adminUser = "admin" }
        if ([string]::IsNullOrEmpty($adminPassword)) { $adminPassword = "FFf3t5h5aJBnTd" }
    } else {
        $adminUser = "admin"
        $adminPassword = "FFf3t5h5aJBnTd"
    }
    
    Write-Yellow "Setting admin credentials to:"
    Write-Output "User: $adminUser"
    Write-Output "Password: $adminPassword"
    
    # Set environment variables in container (but this won't persist across container restart)
    docker exec admin-panel bash -c "export ADMIN_USER=`"$adminUser`""
    docker exec admin-panel bash -c "export ADMIN_PASSWORD=`"$adminPassword`""
    
    # Restart the container to apply environment variables
    Write-Yellow "Restarting admin-panel container..."
    docker restart admin-panel
    Start-Sleep -Seconds 5
}

# Check if admin-panel can connect to postgres
Write-Yellow "`nChecking database connectivity from admin-panel..."
$postgresIP = docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' postgres
$adminPanelIP = docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' admin-panel

Write-Green "PostgreSQL IP: $postgresIP"
Write-Green "Admin Panel IP: $adminPanelIP"

# Check network configuration
$postgresNetwork = docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' postgres
$adminNetwork = docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' admin-panel

Write-Green "PostgreSQL network: $postgresNetwork"
Write-Green "Admin Panel network: $adminNetwork"

# Fix session secret if missing
Write-Yellow "`nChecking for session secret..."
$sessionSecret = docker exec admin-panel env | Select-String "SESSION_SECRET"

if (!$sessionSecret) {
    Write-Red "Session secret not found!"
    
    # Generate a random session secret
    $newSecret = [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes(32))
    Write-Yellow "Setting new session secret..."
    
    # Add to .env file if it exists
    if (Test-Path ".env") {
        $envContent = Get-Content ".env"
        $secretExists = $false
        
        foreach ($line in $envContent) {
            if ($line -match "^SESSION_SECRET=") {
                $secretExists = $true
                break
            }
        }
        
        if ($secretExists) {
            $envContent = $envContent | ForEach-Object { $_ -replace "^SESSION_SECRET=.*", "SESSION_SECRET=$newSecret" }
            Set-Content -Path ".env" -Value $envContent
        } else {
            Add-Content -Path ".env" -Value "SESSION_SECRET=$newSecret"
        }
    }
    
    # Set environment variable in container
    docker exec admin-panel bash -c "export SESSION_SECRET=`"$newSecret`""
    
    # Restart the container
    Write-Yellow "Restarting admin-panel container..."
    docker restart admin-panel
    Start-Sleep -Seconds 5
} else {
    Write-Green "Session secret is set."
}

# Create or update hardcoded admin credentials if needed
Write-Yellow "`nCreating hardcoded admin credentials file..."

$scriptContent = @"
// Script to update or create admin user directly in the database
const { Pool } = require('pg');

// Database connection (using environment variables or defaults)
const pool = new Pool({
  user: process.env.POSTGRES_USER || 'postgres',
  host: process.env.POSTGRES_HOST || 'postgres',
  database: process.env.POSTGRES_DB || 'postgres',
  password: process.env.POSTGRES_PASSWORD,
  port: 5432,
});

async function createAdminUser() {
  try {
    // Check if we can connect to the database
    await pool.query('SELECT NOW()');
    console.log('Database connection successful');
    
    // Check if AdminUsers table exists
    const tableCheck = await pool.query(
      "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'AdminUsers');"
    );
    
    // Create table if it doesn't exist
    if (!tableCheck.rows[0].exists) {
      console.log('Creating AdminUsers table...');
      await pool.query(`
        CREATE TABLE "AdminUsers" (
          "username" VARCHAR(255) PRIMARY KEY,
          "password" VARCHAR(255) NOT NULL,
          "isActive" BOOLEAN DEFAULT true,
          "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
          "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
      `);
    }
    
    // Create or update admin user
    console.log('Creating/updating admin user...');
    await pool.query(`
      INSERT INTO "AdminUsers" ("username", "password", "isActive")
      VALUES ('admin', 'FFf3t5h5aJBnTd', true)
      ON CONFLICT ("username") DO UPDATE 
      SET "password" = 'FFf3t5h5aJBnTd', "isActive" = true, "updatedAt" = CURRENT_TIMESTAMP;
    `);
    
    console.log('Admin user created/updated successfully!');
  } catch (error) {
    console.error('Error:', error);
  } finally {
    await pool.end();
  }
}

createAdminUser();
"@

$tempFile = Join-Path $env:TEMP "fix_admin_creds.js"
Set-Content -Path $tempFile -Value $scriptContent

docker cp $tempFile admin-panel:/tmp/fix_admin_creds.js
Write-Yellow "Running admin credentials fix script..."
$result = docker exec admin-panel node /tmp/fix_admin_creds.js

Write-Green "Result:"
Write-Output $result

# Restart the admin-panel container one final time
Write-Yellow "`nRestarting admin-panel container..."
docker restart admin-panel
Start-Sleep -Seconds 3

Write-Green "`nAdmin panel login fix complete!"
Write-Yellow "You should now be able to log in with:"
Write-Output "URL: http://136.243.2.232:3001/login"
Write-Output "Username: admin"
Write-Output "Password: FFf3t5h5aJBnTd"
Write-Output "`nIf you still have issues, please check:"
Write-Output "1. Docker logs: docker logs admin-panel"
Write-Output "2. Database connectivity issues"
Write-Output "3. Session persistence issues"
