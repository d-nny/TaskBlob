/**
 * Password utility functions for secure password handling
 * Uses Argon2id for password hashing - one of the strongest algorithms available
 */

const argon2 = require('argon2');
const crypto = require('crypto');

// Configuration for Argon2id
const HASH_OPTIONS = {
  // Argon2id variant provides the best balance of security against both side-channel attacks and GPU attacks
  type: argon2.argon2id,
  // Memory cost: 64 MiB (recommended for server-side applications)
  memoryCost: 65536,
  // Time cost: number of iterations (higher is more secure but slower)
  timeCost: 3,
  // Parallelism: number of threads to use
  parallelism: 2,
  // Output hash length
  hashLength: 32
};

/**
 * Generate a secure random password
 * @param {number} length - Length of the password
 * @returns {string} - Secure random password
 */
const generateSecurePassword = (length = 16) => {
  // We're using a cryptographically secure random number generator
  const bytes = crypto.randomBytes(length);
  // Convert to base64 and ensure we have only URL-safe characters
  const password = bytes.toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
  
  return password.slice(0, length);
};

/**
 * Hash a password using Argon2id
 * @param {string} password - Plain text password
 * @returns {Promise<string>} - Hashed password
 */
const hashPassword = async (password) => {
  try {
    // Generate a random salt (Argon2 does this automatically)
    return await argon2.hash(password, HASH_OPTIONS);
  } catch (error) {
    console.error('Error hashing password:', error);
    throw error;
  }
};

/**
 * Verify a password against a hash
 * @param {string} hash - Stored password hash
 * @param {string} password - Plain text password to verify
 * @returns {Promise<boolean>} - True if password matches
 */
const verifyPassword = async (hash, password) => {
  try {
    return await argon2.verify(hash, password);
  } catch (error) {
    console.error('Error verifying password:', error);
    throw error;
  }
};

module.exports = {
  generateSecurePassword,
  hashPassword,
  verifyPassword
};
