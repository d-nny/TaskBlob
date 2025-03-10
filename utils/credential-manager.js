/**
 * Credential Manager
 * Securely manages application passwords using a master password
 * - Generates strong random passwords for services
 * - Encrypts service passwords using master password
 * - Provides secure storage and retrieval
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { promisify } = require('util');

// Promisify fs functions
const writeFile = promisify(fs.writeFile);
const readFile = promisify(fs.readFile);
const mkdir = promisify(fs.mkdir);

// Async function to check if a file exists
const exists = async (path) => {
  try {
    await promisify(fs.access)(path);
    return true;
  } catch {
    return false;
  }
};

// Constants
const CREDENTIALS_DIR = process.env.CREDENTIALS_DIR || '/var/server/credentials';
const CREDENTIALS_FILE = path.join(CREDENTIALS_DIR, 'credentials.enc');
const ENCRYPTION_ALGORITHM = 'aes-256-gcm';
const KEY_LENGTH = 32; // 256 bits
const SALT_LENGTH = 32;
const IV_LENGTH = 16;
const AUTH_TAG_LENGTH = 16;
const KEY_ITERATIONS = 100000; // PBKDF2 iterations (higher = more secure but slower)

/**
 * Derive a key from the master password
 * @param {string} masterPassword - The master password
 * @param {Buffer} salt - Salt for key derivation
 * @returns {Promise<Buffer>} - Derived key
 */
async function deriveKey(masterPassword, salt) {
  return new Promise((resolve, reject) => {
    crypto.pbkdf2(
      masterPassword,
      salt,
      KEY_ITERATIONS,
      KEY_LENGTH,
      'sha256',
      (err, derivedKey) => {
        if (err) return reject(err);
        resolve(derivedKey);
      }
    );
  });
}

/**
 * Encrypt data with the master password
 * @param {string} data - Data to encrypt
 * @param {string} masterPassword - Master password
 * @returns {Promise<{encrypted: Buffer, salt: Buffer, iv: Buffer, authTag: Buffer}>} - Encrypted data
 */
async function encrypt(data, masterPassword) {
  // Generate a random salt
  const salt = crypto.randomBytes(SALT_LENGTH);
  
  // Derive key from password and salt
  const key = await deriveKey(masterPassword, salt);
  
  // Generate initialization vector
  const iv = crypto.randomBytes(IV_LENGTH);
  
  // Create cipher
  const cipher = crypto.createCipheriv(ENCRYPTION_ALGORITHM, key, iv, {
    authTagLength: AUTH_TAG_LENGTH
  });
  
  // Encrypt the data
  const encrypted = Buffer.concat([
    cipher.update(data, 'utf8'),
    cipher.final()
  ]);
  
  // Get authentication tag
  const authTag = cipher.getAuthTag();
  
  return { encrypted, salt, iv, authTag };
}

/**
 * Decrypt data with the master password
 * @param {Buffer} encrypted - Encrypted data
 * @param {Buffer} salt - Salt used for key derivation
 * @param {Buffer} iv - Initialization vector
 * @param {Buffer} authTag - Authentication tag
 * @param {string} masterPassword - Master password
 * @returns {Promise<string>} - Decrypted data
 */
async function decrypt(encrypted, salt, iv, authTag, masterPassword) {
  // Derive key from password and salt
  const key = await deriveKey(masterPassword, salt);
  
  // Create decipher
  const decipher = crypto.createDecipheriv(ENCRYPTION_ALGORITHM, key, iv, {
    authTagLength: AUTH_TAG_LENGTH
  });
  
  // Set auth tag
  decipher.setAuthTag(authTag);
  
  // Decrypt the data
  try {
    const decrypted = Buffer.concat([
      decipher.update(encrypted),
      decipher.final()
    ]);
    
    return decrypted.toString('utf8');
  } catch (error) {
    if (error.message.includes('Unsupported state or unable to authenticate data')) {
      throw new Error('Invalid master password or corrupted data');
    }
    throw error;
  }
}

/**
 * Save credentials to encrypted file
 * @param {Object} credentials - Credentials object
 * @param {string} masterPassword - Master password
 */
async function saveCredentials(credentials, masterPassword) {
  // Ensure credentials directory exists
  await mkdir(CREDENTIALS_DIR, { recursive: true });
  
  // Encrypt credentials
  const data = JSON.stringify(credentials);
  const { encrypted, salt, iv, authTag } = await encrypt(data, masterPassword);
  
  // Format for storage
  const encryptedData = Buffer.concat([
    Buffer.from([salt.length]), // 1 byte for salt length
    salt,
    Buffer.from([iv.length]), // 1 byte for iv length
    iv,
    Buffer.from([authTag.length]), // 1 byte for auth tag length
    authTag,
    encrypted
  ]);
  
  // Write to file
  await writeFile(CREDENTIALS_FILE, encryptedData);
}

/**
 * Load credentials from encrypted file
 * @param {string} masterPassword - Master password
 * @returns {Promise<Object>} - Decrypted credentials
 */
async function loadCredentials(masterPassword) {
  // Check if credentials file exists
  const fileExists = await exists(CREDENTIALS_FILE);
  if (!fileExists) {
    return null;
  }
  
  // Read encrypted data
  const encryptedData = await readFile(CREDENTIALS_FILE);
  
  // Parse the data format
  let offset = 0;
  
  // Extract salt
  const saltLength = encryptedData[offset];
  offset += 1;
  const salt = encryptedData.slice(offset, offset + saltLength);
  offset += saltLength;
  
  // Extract IV
  const ivLength = encryptedData[offset];
  offset += 1;
  const iv = encryptedData.slice(offset, offset + ivLength);
  offset += ivLength;
  
  // Extract auth tag
  const authTagLength = encryptedData[offset];
  offset += 1;
  const authTag = encryptedData.slice(offset, offset + authTagLength);
  offset += authTagLength;
  
  // Extract encrypted data
  const encrypted = encryptedData.slice(offset);
  
  // Decrypt the data
  try {
    const decryptedData = await decrypt(encrypted, salt, iv, authTag, masterPassword);
    return JSON.parse(decryptedData);
  } catch (error) {
    throw new Error(`Failed to decrypt credentials: ${error.message}`);
  }
}

/**
 * Generate a secure random password
 * @param {number} length - Password length
 * @returns {string} - Random password
 */
function generatePassword(length = 32) {
  const bytes = crypto.randomBytes(Math.ceil(length * 3 / 4));
  // Use base64 but make it more URL-safe and remove padding
  const password = bytes.toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
  
  return password.slice(0, length);
}

/**
 * Initialize or load credentials using master password
 * @param {string} masterPassword - Master password
 * @returns {Promise<Object>} - Service credentials
 */
async function initializeCredentials(masterPassword) {
  if (!masterPassword) {
    throw new Error('Master password is required');
  }
  
  // Try to load existing credentials
  try {
    const credentials = await loadCredentials(masterPassword);
    if (credentials) {
      return credentials;
    }
  } catch (error) {
    console.error('Error loading credentials:', error.message);
    throw error;
  }
  
  // If no credentials exist, generate new ones
  console.log('Generating new service credentials...');
  
  const credentials = {
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    postgres: {
      password: generatePassword(24)
    },
    redis: {
      password: generatePassword(24)
    },
    mail: {
      password: generatePassword(24)
    },
    roundcube: {
      password: generatePassword(24)
    },
    admin: {
      password: generatePassword(16)
    },
    session: {
      secret: generatePassword(32)
    }
  };
  
  // Save the new credentials
  await saveCredentials(credentials, masterPassword);
  console.log('New credentials generated and saved');
  
  return credentials;
}

/**
 * Set environment variables from credentials
 * @param {Object} credentials - Service credentials
 */
function setEnvironmentVariables(credentials) {
  // PostgreSQL
  process.env.POSTGRES_PASSWORD = credentials.postgres.password;
  
  // Redis
  process.env.REDIS_PASSWORD = credentials.redis.password;
  
  // Roundcube webmail
  process.env.ROUNDCUBE_PASSWORD = credentials.roundcube.password;
  
  // Admin panel
  process.env.ADMIN_PASSWORD = credentials.admin.password;
  process.env.SESSION_SECRET = credentials.session.secret;
}

/**
 * Print a credential summary (useful for initial setup)
 * @param {Object} credentials - Service credentials
 */
function printCredentialSummary(credentials) {
  console.log('\n======== CREDENTIAL SUMMARY ========');
  console.log('PostgreSQL Password:', credentials.postgres.password);
  console.log('Redis Password:', credentials.redis.password);
  console.log('Admin Panel Password:', credentials.admin.password);
  console.log('====================================\n');
  
  console.log('These credentials are encrypted with your master password');
  console.log('and stored in:', CREDENTIALS_FILE);
  console.log('They will be automatically used by all services.\n');
}

module.exports = {
  initializeCredentials,
  loadCredentials,
  saveCredentials,
  generatePassword,
  setEnvironmentVariables,
  printCredentialSummary
};
