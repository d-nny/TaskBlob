/**
 * Email Forwarding Model
 * Handles email forwarding rules stored in PostgreSQL
 */

const { Pool } = require('pg');
const pool = new Pool({
  host: process.env.POSTGRES_HOST || 'postgres',
  user: process.env.POSTGRES_USER || 'postgres',
  password: process.env.POSTGRES_PASSWORD || 'postgres',
  database: process.env.POSTGRES_DB || 'postgres',
  port: 5432
});

/**
 * Get all email forwarding rules
 * @returns {Promise<Array>} - List of all forwarding rules
 */
async function getAllForwards() {
  try {
    const result = await pool.query(`
      SELECT f.id, f.source, f.destination, f.enabled, d.domain 
      FROM forwards f
      JOIN domains d ON f.domain_id = d.id
      ORDER BY d.domain, f.source
    `);
    return result.rows;
  } catch (error) {
    console.error('Error fetching forwarding rules:', error);
    throw error;
  }
}

/**
 * Get forwarding rules for a specific domain
 * @param {number} domainId - Domain ID
 * @returns {Promise<Array>} - List of forwarding rules for the domain
 */
async function getForwardsByDomain(domainId) {
  try {
    const result = await pool.query(`
      SELECT f.id, f.source, f.destination, f.enabled, d.domain 
      FROM forwards f
      JOIN domains d ON f.domain_id = d.id
      WHERE f.domain_id = $1
      ORDER BY f.source
    `, [domainId]);
    return result.rows;
  } catch (error) {
    console.error(`Error fetching forwarding rules for domain ${domainId}:`, error);
    throw error;
  }
}

/**
 * Get a specific forwarding rule by ID
 * @param {number} id - Forwarding rule ID
 * @returns {Promise<Object>} - Forwarding rule details
 */
async function getForwardById(id) {
  try {
    const result = await pool.query(`
      SELECT f.id, f.source, f.destination, f.enabled, f.domain_id, d.domain 
      FROM forwards f
      JOIN domains d ON f.domain_id = d.id
      WHERE f.id = $1
    `, [id]);
    return result.rows[0];
  } catch (error) {
    console.error(`Error fetching forwarding rule ${id}:`, error);
    throw error;
  }
}

/**
 * Create a new forwarding rule
 * @param {Object} forward - Forwarding rule data
 * @param {string} forward.source - Source email address (local part only, no domain)
 * @param {string} forward.destination - Destination email address (full address)
 * @param {number} forward.domain_id - Domain ID
 * @param {boolean} forward.enabled - Whether the rule is enabled
 * @returns {Promise<Object>} - Created forwarding rule
 */
async function createForward(forward) {
  try {
    // First check if the source email already exists for this domain
    const checkResult = await pool.query(`
      SELECT COUNT(*) as count FROM forwards 
      WHERE source = $1 AND domain_id = $2
    `, [forward.source, forward.domain_id]);
    
    if (checkResult.rows[0].count > 0) {
      throw new Error('A forwarding rule already exists for this email address');
    }
    
    const result = await pool.query(`
      INSERT INTO forwards (source, destination, domain_id, enabled)
      VALUES ($1, $2, $3, $4)
      RETURNING id, source, destination, domain_id, enabled
    `, [forward.source, forward.destination, forward.domain_id, forward.enabled || true]);
    
    return result.rows[0];
  } catch (error) {
    console.error('Error creating forwarding rule:', error);
    throw error;
  }
}

/**
 * Update an existing forwarding rule
 * @param {number} id - Forwarding rule ID
 * @param {Object} forward - Updated forwarding rule data
 * @returns {Promise<Object>} - Updated forwarding rule
 */
async function updateForward(id, forward) {
  try {
    const result = await pool.query(`
      UPDATE forwards
      SET source = $1, destination = $2, enabled = $3
      WHERE id = $4
      RETURNING id, source, destination, domain_id, enabled
    `, [forward.source, forward.destination, forward.enabled, id]);
    
    return result.rows[0];
  } catch (error) {
    console.error(`Error updating forwarding rule ${id}:`, error);
    throw error;
  }
}

/**
 * Delete a forwarding rule
 * @param {number} id - Forwarding rule ID
 * @returns {Promise<boolean>} - Success status
 */
async function deleteForward(id) {
  try {
    await pool.query('DELETE FROM forwards WHERE id = $1', [id]);
    return true;
  } catch (error) {
    console.error(`Error deleting forwarding rule ${id}:`, error);
    throw error;
  }
}

/**
 * Toggle the enabled status of a forwarding rule
 * @param {number} id - Forwarding rule ID
 * @returns {Promise<Object>} - Updated forwarding rule
 */
async function toggleForwardStatus(id) {
  try {
    const result = await pool.query(`
      UPDATE forwards
      SET enabled = NOT enabled
      WHERE id = $1
      RETURNING id, source, destination, domain_id, enabled
    `, [id]);
    
    return result.rows[0];
  } catch (error) {
    console.error(`Error toggling forwarding rule ${id} status:`, error);
    throw error;
  }
}

// Ensure the forwards table exists
async function initForwardsTable() {
  try {
    // Check if the table exists
    const tableCheck = await pool.query(`
      SELECT EXISTS (
        SELECT FROM information_schema.tables 
        WHERE table_schema = 'public' AND table_name = 'forwards'
      );
    `);
    
    if (!tableCheck.rows[0].exists) {
      console.log('Creating forwards table...');
      await pool.query(`
        CREATE TABLE forwards (
          id SERIAL PRIMARY KEY,
          source VARCHAR(255) NOT NULL,
          destination VARCHAR(255) NOT NULL,
          domain_id INTEGER NOT NULL REFERENCES domains(id) ON DELETE CASCADE,
          enabled BOOLEAN DEFAULT TRUE,
          created_at TIMESTAMP DEFAULT NOW()
        );
        CREATE INDEX forwards_domain_id_idx ON forwards(domain_id);
        CREATE UNIQUE INDEX forwards_source_domain_idx ON forwards(source, domain_id);
      `);
      console.log('Forwards table created successfully');
    }
  } catch (error) {
    console.error('Error initializing forwards table:', error);
  }
}

module.exports = {
  getAllForwards,
  getForwardsByDomain,
  getForwardById,
  createForward,
  updateForward,
  deleteForward,
  toggleForwardStatus,
  initForwardsTable
};
