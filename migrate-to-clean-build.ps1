# PowerShell script to migrate fix scripts to clean build approach

Write-Host "TaskBlob - Migrating to Clean Build Approach" -ForegroundColor Yellow
Write-Host "======================================="

# Step 1: Update server.js with the consolidated version
Write-Host "`nStep 1: Updating server.js with consolidated fixes..." -ForegroundColor Yellow
if (Test-Path "config-admin/server.js.updated") {
    # Backup original first
    if (Test-Path "config-admin/server.js") {
        Copy-Item -Path "config-admin/server.js" -Destination "config-admin/server.js.backup"
        Write-Host "  Original server.js backed up to server.js.backup" -ForegroundColor Green
    }
    
    # Replace with updated version
    Copy-Item -Path "config-admin/server.js.updated" -Destination "config-admin/server.js" -Force
    Write-Host "  server.js updated with consolidated version" -ForegroundColor Green
    
    # Remove the updated file
    Remove-Item -Path "config-admin/server.js.updated" -Force
    Write-Host "  Removed temporary server.js.updated file" -ForegroundColor Green
} else {
    Write-Host "  server.js.updated not found!" -ForegroundColor Red
}

# Step 2: Update Dockerfile
Write-Host "`nStep 2: Updating admin panel Dockerfile..." -ForegroundColor Yellow
if (Test-Path "config-admin/Dockerfile.updated") {
    # Backup original first
    if (Test-Path "config-admin/Dockerfile") {
        Copy-Item -Path "config-admin/Dockerfile" -Destination "config-admin/Dockerfile.backup"
        Write-Host "  Original Dockerfile backed up to Dockerfile.backup" -ForegroundColor Green
    }
    
    # Replace with updated version
    Copy-Item -Path "config-admin/Dockerfile.updated" -Destination "config-admin/Dockerfile" -Force
    Write-Host "  Dockerfile updated with new version" -ForegroundColor Green
    
    # Remove the updated file
    Remove-Item -Path "config-admin/Dockerfile.updated" -Force
    Write-Host "  Removed temporary Dockerfile.updated file" -ForegroundColor Green
} else {
    Write-Host "  Dockerfile.updated not found!" -ForegroundColor Red
}

# Step 3: Update docker-compose.yml
Write-Host "`nStep 3: Updating docker-compose.yml..." -ForegroundColor Yellow
if (Test-Path "docker-compose.updated.yml") {
    # Backup original first
    if (Test-Path "docker-compose.yml") {
        Copy-Item -Path "docker-compose.yml" -Destination "docker-compose.yml.backup"
        Write-Host "  Original docker-compose.yml backed up to docker-compose.yml.backup" -ForegroundColor Green
    }
    
    # Replace with updated version
    Copy-Item -Path "docker-compose.updated.yml" -Destination "docker-compose.yml" -Force
    Write-Host "  docker-compose.yml updated with new version" -ForegroundColor Green
    
    # Remove the updated file
    Remove-Item -Path "docker-compose.updated.yml" -Force
    Write-Host "  Removed temporary docker-compose.updated.yml file" -ForegroundColor Green
} else {
    Write-Host "  docker-compose.updated.yml not found!" -ForegroundColor Red
}

# Step 4: Create a backup directory for fix scripts
Write-Host "`nStep 4: Moving fix scripts to backup directory..." -ForegroundColor Yellow
$backupDir = "fix-scripts-backup"
if (-not (Test-Path $backupDir)) {
    New-Item -Path $backupDir -ItemType Directory
    Write-Host "  Created backup directory: $backupDir" -ForegroundColor Green
}

# List of fix scripts to be moved to backup
$fixScripts = @(
    "fix-root-route.sh",
    "fix-admin-login.sh",
    "fix-admin-login-v2.sh",
    "direct-db-login-fix.sh",
    "Fix-AdminLogin.ps1",
    "consolidate-fixes.sh",
    "Consolidate-Fixes.ps1"
)

foreach ($script in $fixScripts) {
    if (Test-Path $script) {
        Move-Item -Path $script -Destination "$backupDir/" -Force
        Write-Host "  Moved $script to backup directory" -ForegroundColor Green
    } else {
        Write-Host "  Script $script not found, skipping" -ForegroundColor Yellow
    }
}

# Step 5: Instructions for rebuilding
Write-Host "`nStep 5: Next steps for clean rebuild" -ForegroundColor Yellow
Write-Host "  To apply all changes, please run:" -ForegroundColor Green
Write-Host "  docker-compose down" -ForegroundColor Cyan
Write-Host "  docker-compose up -d --build" -ForegroundColor Cyan
Write-Host "`n  This will create a clean build with all fixes properly integrated." -ForegroundColor Green
Write-Host "  The admin panel should now work correctly out of the box" -ForegroundColor Green
Write-Host "  without requiring any additional fix scripts." -ForegroundColor Green

Write-Host "`nMigration to clean build approach complete!" -ForegroundColor Yellow
Write-Host "You can now access the admin panel at: http://localhost:3001" -ForegroundColor Cyan
Write-Host "Default login: admin / FFf3t5h5aJBnTd (or as specified in your .env file)" -ForegroundColor Cyan
