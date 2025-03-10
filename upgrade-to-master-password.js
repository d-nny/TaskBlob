#!/usr/bin/env node

/**
 * Upgrade to Master Password System
 * 
 * This script migrates existing installations from individual service passwords
 * to the new master password system.
 * 
 * It will:
 * 1. Extract existing service passwords from .env
 * 2. Create a secure master password
 * 3. Encrypt all existing passwords with the master password
 * 4. Update .env to use the master password system
 * 
 * Usage: node upgrade-to-master-password.js
 */

const fs = require('fs').promises;
const path = require('path');
const readline = require('readline');
const dotenv = require('dotenv');
const credentialManager = require('./utils/credential-manager');

// Load environment variables
dotenv.config();

// Create readline interface
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

/**
 * Prompt the user with a question
 * @param {string} question - Question to ask
 * @returns {Promise<string>} - User's answer
 */
function prompt(question) {
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      resolve(answer);
    });
  });
}

/**
 * Prompt for password (without displaying it)
 * @param {string} question - Question to ask
 * @returns {Promise<string>} - User's password
 */
async function promptPassword(question) {
  // Note: In a real implementation, we would use a package like 'stdin-password'
  // to hide the password as it's typed. For simplicity in this script,
  // we're using a regular prompt.
  console.log('Warning: Password will be visible as you type');
  console.log('In production, use this with a proper TTY password input');
  return prompt(question);
}

/**
 * Extract existing credentials from .env file
 * @returns {Object} - Extracted credentials
 */
function extractExistingCredentials() {
  const credentials = {
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    postgres: {
      password: process.env.POSTGRES_PASSWORD || null
    },
    redis: {
      password: process.env.REDIS_PASSWORD || null
    },
    mail: {
      password: process.env.MAIL_PASSWORD || null
    },
    roundcube: {
      password: process.env.ROUNDCUBE_PASSWORD || null
    },
    admin: {
      password: process.env.ADMIN_PASSWORD || null
    },
    session: {
      secret: process.env.SESSION_SECRET || null
    }
  };
  
  return credentials;
}

/**
 * Generate a new .env file with master password
 * @param {string} masterPassword - Master password
 */
async function updateEnvFile(masterPassword) {
  // Read the existing .env file
  let envContent;
  try {
    envContent = await fs.readFile('.env', 'utf8');
  } catch (error) {
    console.error('Error reading .env file:', error.message);
    return false;
  }
  
  // Make a backup of the original .env file
  const backupPath = `.env.backup-${Date.now()}`;
  await fs.writeFile(backupPath, envContent);
  console.log(`Backup of original .env file created at ${backupPath}`);
  
  // Parse the current environment variables
  const envVars = {};
  const lines = envContent.split('\n');
  
  for (const line of lines) {
    // Skip comments and empty lines
    if (line.trim().startsWith('#') || line.trim() === '') continue;
    
    // Parse key=value pairs
    const match = line.match(/^\s*([^#=]+)=(.*)$/);
    if (match) {
      const key = match[1].trim();
      const value = match[2].trim();
      envVars[key] = value;
    }
  }
  
  // Add the master password
  envVars.MASTER_PASSWORD = masterPassword;
  
  // Remove service passwords that will be managed by the credential manager
  const passwordKeys = [
    'POSTGRES_PASSWORD',
    'REDIS_PASSWORD',
    'MAIL_PASSWORD',
    'ROUNDCUBE_PASSWORD',
    'ADMIN_PASSWORD',
    'SESSION_SECRET'
  ];
  
  passwordKeys.forEach(key => {
    delete envVars[key];
  });
  
  // Set credentials directory if not already set
  if (!envVars.CREDENTIALS_DIR) {
    envVars.CREDENTIALS_DIR = '/var/server/credentials';
  }
  
  // Generate the new .env file content
  let newEnvContent = `# Environment variables for TaskBlob Server\n`;
  newEnvContent += `# Upgraded to master password system on ${new Date().toISOString()}\n\n`;
  
  newEnvContent += `# Master password - KEEP THIS SECRET AND SECURE\n`;
  newEnvContent += `# This is used to decrypt all service credentials\n`;
  newEnvContent += `MASTER_PASSWORD=${envVars.MASTER_PASSWORD}\n\n`;
  
  // Add remaining environment variables, grouping them by type
  const groups = {
    'Domain settings': ['DOMAIN', 'ADMIN_EMAIL', 'MAIL_HOST'],
    'Cloudflare API credentials': ['CLOUDFLARE_API_KEY', 'CLOUDFLARE_EMAIL'],
    'IP Address settings': ['PRIMARY_IP', 'MAIL_IP', 'IPV6_PREFIX'],
    'Admin settings': ['ADMIN_USER'],
    'Credentials': ['CREDENTIALS_DIR']
  };
  
  // Add variables by group
  for (const [groupName, keys] of Object.entries(groups)) {
    const groupVars = keys.filter(key => envVars[key] !== undefined);
    
    if (groupVars.length > 0) {
      newEnvContent += `# ${groupName}\n`;
      
      for (const key of groupVars) {
        newEnvContent += `${key}=${envVars[key]}\n`;
      }
      
      newEnvContent += '\n';
    }
  }
  
  // Add any remaining variables that weren't in a group
  const groupedKeys = Object.values(groups).flat();
  const remainingKeys = Object.keys(envVars)
    .filter(key => key !== 'MASTER_PASSWORD' && !groupedKeys.includes(key));
  
  if (remainingKeys.length > 0) {
    newEnvContent += `# Other settings\n`;
    
    for (const key of remainingKeys) {
      newEnvContent += `${key}=${envVars[key]}\n`;
    }
    
    newEnvContent += '\n';
  }
  
  // Add comment explaining the migration
  newEnvContent += `# NOTE: Service passwords have been moved to the encrypted credentials file\n`;
  newEnvContent += `# and are no longer stored in this .env file for security.\n`;
  
  // Write the new .env file
  await fs.writeFile('.env', newEnvContent);
  console.log('Updated .env file with master password system');
  
  return true;
}

/**
 * Main function
 */
async function main() {
  console.log('┌──────────────────────────────────────────────────┐');
  console.log('│  Upgrade to TaskBlob Master Password System      │');
  console.log('└──────────────────────────────────────────────────┘');
  console.log('');
  
  console.log('This script will migrate your existing service passwords');
  console.log('to the new master password encryption system.\n');
  
  // Extract existing credentials
  const existingCredentials = extractExistingCredentials();
  
  // Check if we have any existing credentials to migrate
  const hasCredentials = Object.values(existingCredentials)
    .some(category => 
      typeof category === 'object' && 
      category !== null && 
      Object.values(category).some(val => val !== null)
    );
  
  if (!hasCredentials) {
    console.log('⚠️  No existing service credentials found in .env file.');
    const proceed = await prompt('Do you want to proceed with setup anyway? (y/N): ');
    
    if (proceed.toLowerCase() !== 'y') {
      console.log('Operation cancelled.');
      rl.close();
      return;
    }
  }
  
  // Get master password
  console.log('\n📋 Creating master password for all services');
  console.log('   This password will protect all service credentials\n');
  
  let masterPassword;
  let confirmPassword;
  
  do {
    masterPassword = await promptPassword('Enter master password (min 12 chars): ');
    
    if (masterPassword.length < 12) {
      console.log('❌ Password must be at least 12 characters long');
      continue;
    }
    
    confirmPassword = await promptPassword('Confirm master password: ');
    
    if (masterPassword !== confirmPassword) {
      console.log('❌ Passwords do not match. Please try again.\n');
    }
  } while (masterPassword.length < 12 || masterPassword !== confirmPassword);
  
  console.log('\n✅ Master password accepted');
  
  try {
    // Fill in any missing credentials with generated ones
    if (!existingCredentials.postgres.password) {
      existingCredentials.postgres.password = credentialManager.generatePassword(24);
      console.log('Generated new PostgreSQL password');
    }
    
    if (!existingCredentials.redis.password) {
      existingCredentials.redis.password = credentialManager.generatePassword(24);
      console.log('Generated new Redis password');
    }
    
    if (!existingCredentials.roundcube.password) {
      existingCredentials.roundcube.password = credentialManager.generatePassword(24);
      console.log('Generated new Roundcube password');
    }
    
    if (!existingCredentials.admin.password) {
      existingCredentials.admin.password = credentialManager.generatePassword(16);
      console.log('Generated new Admin password');
    }
    
    if (!existingCredentials.session.secret) {
      existingCredentials.session.secret = credentialManager.generatePassword(32);
      console.log('Generated new Session secret');
    }
    
    // Save the credentials with encryption
    console.log('\n🔑 Encrypting service credentials with master password...');
    await credentialManager.saveCredentials(existingCredentials, masterPassword);
    
    // Print a summary
    credentialManager.printCredentialSummary(existingCredentials);
    
    // Update the .env file
    await updateEnvFile(masterPassword);
    
    console.log('\n✅ Migration to master password system complete!');
    console.log('   Your master password is now the only password you need to remember.');
    console.log('   All service passwords are securely encrypted and will be');
    console.log('   automatically loaded by the system as needed.\n');
    
    console.log('🔐 IMPORTANT: Keep your master password secure!');
    console.log('   If you lose it, you will need to regenerate all credentials.');
    
    console.log('\n📝 Next steps:');
    console.log('   1. Use the bootstrap.js script to run commands with credentials:');
    console.log('      node bootstrap.js docker-compose up -d');
    console.log('   2. Update your services to use the new credential system');
  } catch (error) {
    console.error('❌ Error during migration:', error.message);
  }
  
  rl.close();
}

// Run the main function
main().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
