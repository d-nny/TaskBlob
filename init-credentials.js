#!/usr/bin/env node

/**
 * Master Password Initialization Script
 * 
 * Sets up the master password and initializes all service credentials
 * - Creates encrypted credentials file secured with master password
 * - Generates secure random passwords for all services
 * - Updates .env file to include only master password
 * 
 * Usage: node init-credentials.js
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
 * Generate and save .env file with master password
 * @param {string} masterPassword - Master password
 */
async function generateEnvFile(masterPassword) {
  // Define the environment variables we want to keep in .env
  const envVars = {
    // Master password for credential access
    MASTER_PASSWORD: masterPassword,
    
    // Domain settings (keep these)
    DOMAIN: process.env.DOMAIN || 'example.com',
    ADMIN_EMAIL: process.env.ADMIN_EMAIL || `admin@example.com`,
    MAIL_HOST: process.env.MAIL_HOST || `mail.example.com`,
    
    // Cloudflare API credentials (keep these)
    CLOUDFLARE_API_KEY: process.env.CLOUDFLARE_API_KEY || '',
    CLOUDFLARE_EMAIL: process.env.CLOUDFLARE_EMAIL || '',
    
    // IP Address settings (keep these)
    PRIMARY_IP: process.env.PRIMARY_IP || '',
    MAIL_IP: process.env.MAIL_IP || '',
    IPV6_PREFIX: process.env.IPV6_PREFIX || '',
    
    // Admin user
    ADMIN_USER: process.env.ADMIN_USER || 'admin',
    
    // Credentials directory
    CREDENTIALS_DIR: process.env.CREDENTIALS_DIR || '/var/server/credentials'
  };
  
  // Generate the .env file content
  let envContent = `# Environment variables for TaskBlob Server\n`;
  envContent += `# Generated on ${new Date().toISOString()}\n\n`;
  
  envContent += `# Master password - KEEP THIS SECRET AND SECURE\n`;
  envContent += `# This is used to decrypt all service credentials\n`;
  envContent += `MASTER_PASSWORD=${envVars.MASTER_PASSWORD}\n\n`;
  
  envContent += `# Domain settings\n`;
  envContent += `DOMAIN=${envVars.DOMAIN}\n`;
  envContent += `ADMIN_EMAIL=${envVars.ADMIN_EMAIL}\n`;
  envContent += `MAIL_HOST=${envVars.MAIL_HOST}\n\n`;
  
  envContent += `# Cloudflare API credentials\n`;
  envContent += `CLOUDFLARE_API_KEY=${envVars.CLOUDFLARE_API_KEY}\n`;
  envContent += `CLOUDFLARE_EMAIL=${envVars.CLOUDFLARE_EMAIL}\n\n`;
  
  envContent += `# IP Address settings\n`;
  envContent += `PRIMARY_IP=${envVars.PRIMARY_IP}\n`;
  envContent += `MAIL_IP=${envVars.MAIL_IP}\n`;
  envContent += `IPV6_PREFIX=${envVars.IPV6_PREFIX}\n\n`;
  
  envContent += `# Admin settings\n`;
  envContent += `ADMIN_USER=${envVars.ADMIN_USER}\n\n`;
  
  envContent += `# Credentials\n`;
  envContent += `CREDENTIALS_DIR=${envVars.CREDENTIALS_DIR}\n`;
  
  // Write to .env file
  await fs.writeFile('.env', envContent);
  console.log('Updated .env file with master password');
}

/**
 * Main function
 */
async function main() {
  console.log('┌──────────────────────────────────────────┐');
  console.log('│  TaskBlob Server Credential Initializer  │');
  console.log('└──────────────────────────────────────────┘');
  console.log('');
  
  // Check if credentials already exist
  const credentialsExist = await fs.access(
    process.env.CREDENTIALS_DIR ? 
    path.join(process.env.CREDENTIALS_DIR, 'credentials.enc') : 
    '/var/server/credentials/credentials.enc'
  ).then(() => true).catch(() => false);
  
  if (credentialsExist) {
    console.log('⚠️  Credentials already exist. Reinitializing will generate new passwords.');
    const confirm = await prompt('Do you want to continue? (y/N): ');
    
    if (confirm.toLowerCase() !== 'y') {
      console.log('Operation cancelled. Existing credentials preserved.');
      rl.close();
      return;
    }
  }
  
  // Get master password
  console.log('\n📋 Creating master password for all services');
  console.log('   This password will protect all other service credentials\n');
  
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
    // Initialize credentials
    console.log('\n🔑 Generating and encrypting service passwords...');
    const credentials = await credentialManager.initializeCredentials(masterPassword);
    
    // Print summary
    credentialManager.printCredentialSummary(credentials);
    
    // Update .env file
    await generateEnvFile(masterPassword);
    
    console.log('\n✅ Credential initialization complete!');
    console.log('   Your master password is now the only password you need to remember.');
    console.log('   All service passwords are securely encrypted and will be');
    console.log('   automatically loaded by the system as needed.\n');
    
    console.log('🔐 IMPORTANT: Keep your master password secure!');
    console.log('   If you lose it, you will need to regenerate all credentials.');
  } catch (error) {
    console.error('❌ Error initializing credentials:', error.message);
  }
  
  rl.close();
}

// Run the main function
main().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
