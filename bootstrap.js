#!/usr/bin/env node

/**
 * TaskBlob Server Bootstrap Script
 * 
 * This script is the entry point for server initialization:
 * - Loads master password from environment
 * - Decrypts service credentials
 * - Sets environment variables for all services
 * - Starts requested service or command
 * 
 * Usage:
 *   node bootstrap.js [command]
 * 
 * Examples:
 *   node bootstrap.js docker-compose up
 *   node bootstrap.js ./master-setup.sh mydomain.com
 */

require('dotenv').config();
const { spawn } = require('child_process');
const credentialManager = require('./utils/credential-manager');

// Check if credentials need to be initialized
async function checkCredentials() {
  const masterPassword = process.env.MASTER_PASSWORD;
  
  if (!masterPassword) {
    console.error('❌ MASTER_PASSWORD not found in environment');
    console.error('Please run init-credentials.js first to set up your master password');
    process.exit(1);
  }
  
  try {
    // Load credentials
    console.log('🔑 Loading service credentials...');
    const credentials = await credentialManager.loadCredentials(masterPassword);
    
    if (!credentials) {
      console.error('❌ No credentials found. Please run init-credentials.js first');
      process.exit(1);
    }
    
    // Set environment variables from credentials
    credentialManager.setEnvironmentVariables(credentials);
    
    console.log('✅ Service credentials loaded successfully');
    return true;
  } catch (error) {
    if (error.message.includes('Invalid master password')) {
      console.error('❌ Invalid master password. Please check your MASTER_PASSWORD in .env');
    } else {
      console.error('❌ Error loading credentials:', error.message);
    }
    process.exit(1);
  }
}

/**
 * Execute a command with credentials loaded into environment
 * @param {Array<string>} args - Command and arguments to execute
 */
async function executeCommand(args) {
  if (args.length === 0) {
    console.log('No command specified. Credentials are loaded into environment.');
    console.log('You can now run commands that need access to service credentials.');
    return;
  }
  
  const command = args[0];
  const commandArgs = args.slice(1);
  
  console.log(`🚀 Executing: ${command} ${commandArgs.join(' ')}`);
  
  // Spawn child process with inherited stdio
  const child = spawn(command, commandArgs, {
    stdio: 'inherit',
    shell: true,
    env: process.env
  });
  
  // Handle process exit
  child.on('close', code => {
    process.exit(code);
  });
  
  // Handle process errors
  child.on('error', err => {
    console.error(`❌ Error executing command: ${err.message}`);
    process.exit(1);
  });
}

/**
 * Main function
 */
async function main() {
  // Get command line arguments (skip node and script name)
  const args = process.argv.slice(2);
  
  // Display welcome message
  console.log('┌──────────────────────────────────────┐');
  console.log('│  TaskBlob Server Bootstrap           │');
  console.log('└──────────────────────────────────────┘');
  
  // Check and load credentials
  const success = await checkCredentials();
  if (!success) return;
  
  // Execute command if provided
  await executeCommand(args);
}

// Run the main function
main().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
