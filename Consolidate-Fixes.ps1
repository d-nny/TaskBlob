# PowerShell script to consolidate all fixes into the original build and clean up individual fix scripts

Write-Host "TaskBlob Admin Panel Fix Consolidation" -ForegroundColor Yellow
Write-Host "======================================="

# Check if the updated server.js exists
if (-not (Test-Path "config-admin/server.js.updated")) {
    Write-Host "Updated server.js file not found!" -ForegroundColor Red
    exit 1
}

# Backup original server.js
Write-Host "`nBacking up original server.js..." -ForegroundColor Yellow
if (Test-Path "config-admin/server.js") {
    Copy-Item -Path "config-admin/server.js" -Destination "config-admin/server.js.bak"
    Write-Host "Original server.js backed up to server.js.bak" -ForegroundColor Green
} else {
    Write-Host "Original server.js not found!" -ForegroundColor Red
    exit 1
}

# Replace server.js with updated version
Write-Host "`nReplacing server.js with consolidated version..." -ForegroundColor Yellow
Copy-Item -Path "config-admin/server.js.updated" -Destination "config-admin/server.js" -Force
Write-Host "Server.js updated with consolidated version" -ForegroundColor Green

# Create a public directory if it doesn't exist
if (-not (Test-Path "config-admin/public")) {
    New-Item -Path "config-admin/public" -ItemType Directory
}

# Create fallback index.html
Write-Host "`nCreating fallback index.html in public directory..." -ForegroundColor Yellow
$indexHtml = @"
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="0;url=/login">
  <title>Redirecting to Login</title>
</head>
<body>
  <h1>Redirecting to Login Page...</h1>
  <p>If you are not redirected automatically, please <a href="/login">click here</a>.</p>
  <script>window.location.href = '/login';</script>
</body>
</html>
"@

Set-Content -Path "config-admin/public/index.html" -Value $indexHtml
Write-Host "Fallback index.html created" -ForegroundColor Green

# Add pg module to package.json if it doesn't exist
Write-Host "`nEnsuring pg module is in package.json..." -ForegroundColor Yellow
if (Test-Path "config-admin/package.json") {
    $packageJson = Get-Content -Path "config-admin/package.json" -Raw
    if ($packageJson -match '"pg":') {
        Write-Host "pg module already exists in package.json" -ForegroundColor Green
    } else {
        $packageJson = $packageJson -replace '"dependencies": {', '"dependencies": {' + "`r`n    `"pg`": `"^8.7.1`","
        Set-Content -Path "config-admin/package.json" -Value $packageJson
        Write-Host "Added pg module to package.json" -ForegroundColor Green
    }
} else {
    Write-Host "package.json not found!" -ForegroundColor Red
}

# Create list of fix scripts to be removed
Write-Host "`nIdentifying fix scripts to be removed..." -ForegroundColor Yellow
$fixScripts = @(
    "fix-root-route.sh",
    "fix-admin-login.sh",
    "fix-admin-login-v2.sh",
    "direct-db-login-fix.sh",
    "Fix-AdminLogin.ps1"
)

# Create backup directory for removed scripts
$backupDir = "fix-scripts-backup"
if (-not (Test-Path $backupDir)) {
    New-Item -Path $backupDir -ItemType Directory
}

# Move fix scripts to backup directory
Write-Host "`nMoving fix scripts to backup directory..." -ForegroundColor Yellow
foreach ($script in $fixScripts) {
    if (Test-Path $script) {
        Move-Item -Path $script -Destination "$backupDir/" -Force
        Write-Host "Moved $script to backup" -ForegroundColor Green
    } else {
        Write-Host "Script $script not found, skipping" -ForegroundColor Yellow
    }
}

# Remove the updated file now that we've copied it
Write-Host "`nRemoving temporary updated server.js file..." -ForegroundColor Yellow
Remove-Item -Path "config-admin/server.js.updated" -Force
Write-Host "Removed config-admin/server.js.updated" -ForegroundColor Green

# Check docker-compose.yml
Write-Host "`nChecking docker-compose.yml for admin-panel configuration..." -ForegroundColor Yellow
if (Test-Path "docker-compose.yml") {
    Write-Host "docker-compose.yml found, you may need to rebuild the admin-panel container" -ForegroundColor Green
    Write-Host "Run 'docker-compose up -d --build admin-panel' to apply changes" -ForegroundColor Yellow
} else {
    Write-Host "docker-compose.yml not found!" -ForegroundColor Red
}

Write-Host "`nConsolidation complete!" -ForegroundColor Green
Write-Host "The following changes have been made:" -ForegroundColor Yellow
Write-Host "1. Server.js has been updated with all fixes"
Write-Host "2. A fallback index.html has been created"
Write-Host "3. Fix scripts have been moved to $backupDir"
Write-Host "4. Package.json has been updated to include pg module"
Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "1. Rebuild and restart the admin-panel container with:"
Write-Host "   docker-compose up -d --build admin-panel"
Write-Host "2. Verify the admin panel is working correctly"
Write-Host "3. Once verified, you can safely remove the $backupDir directory"
