const axios = require('axios');
const { Pool } = require('pg');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const util = require('util');
const execPromise = util.promisify(exec);

// Database connection
const pool = new Pool({
  user: process.env.POSTGRES_USER || 'postgres',
  host: process.env.POSTGRES_HOST || 'postgres',
  database: process.env.POSTGRES_DB || 'postgres',
  password: process.env.POSTGRES_PASSWORD,
  port: 5432,
});

// API URL for config-api service
const API_URL = process.env.CONFIG_API_URL || 'http://config-api:3000';

// DNS Controller methods
const dnsController = {
  // Show DNS configuration
  showDnsConfig: async (req, res) => {
    try {
      const domains = await pool.query('SELECT * FROM mail_domains');
      const { domain } = req.query;
      
      // If domain is specified, get its DNS configuration
      let dnsConfig = null;
      let errors = null;
      let dnsRecords = [];
      
      if (domain) {
        try {
          // Try to get configuration from API
          const response = await axios.get(`${API_URL}/api/dns/${domain}`);
          dnsConfig = response.data;
          
          // Format DNS records for display
          if (dnsConfig && dnsConfig.config && dnsConfig.config.records) {
            const records = dnsConfig.config.records;
            
            // A records
            if (records.a) {
              records.a.forEach(record => {
                dnsRecords.push({
                  type: 'A',
                  name: record.name || '@',
                  content: record.content,
                  proxied: record.proxied ? 'Yes' : 'No'
                });
              });
            }
            
            // MX records
            if (records.mx) {
              records.mx.forEach(record => {
                dnsRecords.push({
                  type: 'MX',
                  name: record.name || '@',
                  content: record.content,
                  priority: record.priority || '10'
                });
              });
            }
            
            // TXT records
            if (records.txt) {
              records.txt.forEach(record => {
                dnsRecords.push({
                  type: 'TXT',
                  name: record.name || '@',
                  content: record.content
                });
              });
            }
            
            // SRV records
            if (records.srv) {
              records.srv.forEach(record => {
                dnsRecords.push({
                  type: 'SRV',
                  name: record.name,
                  service: record.service,
                  proto: record.proto,
                  priority: record.priority || '0',
                  weight: record.weight || '1',
                  port: record.port,
                  target: record.target
                });
              });
            }
          }
        } catch (error) {
          console.error('Error fetching DNS config:', error);
          errors = 'Failed to fetch DNS configuration';
        }
      }
      
      res.render('dns-config', {
        domains: domains.rows,
        selectedDomain: domain,
        dnsConfig,
        dnsRecords,
        errors,
        success: req.query.success
      });
    } catch (error) {
      console.error('Error in DNS configuration page:', error);
      res.status(500).render('dns-config', { 
        domains: [],
        selectedDomain: null,
        dnsConfig: null,
        dnsRecords: [],
        errors: 'Failed to load DNS configuration page'
      });
    }
  },
  
  // Update DNS configuration
  updateDnsConfig: async (req, res) => {
    const { domain } = req.params;
    
    if (!domain) {
      return res.redirect('/dns?error=Domain+is+required');
    }
    
    try {
      // Update DNS records via API
      await axios.post(`${API_URL}/api/dns/${domain}/update`, {}, {
        headers: {
          'X-Cloudflare-Email': process.env.CLOUDFLARE_EMAIL,
          'X-Cloudflare-Api-Key': process.env.CLOUDFLARE_API_KEY
        }
      });
      
      res.redirect(`/dns?domain=${domain}&success=DNS+records+updated+successfully`);
    } catch (error) {
      console.error('Error updating DNS records:', error);
      res.redirect(`/dns?domain=${domain}&error=Failed+to+update+DNS+records`);
    }
  },
  
  // Run DNS setup for a domain
  setupDns: async (req, res) => {
    const { domain } = req.params;
    
    if (!domain) {
      return res.redirect('/dns?error=Domain+is+required');
    }
    
    try {
      // Execute the setup-dns.sh script
      const scriptPath = path.join(process.env.SCRIPTS_DIR || '/var/server', 'setup-dns.sh');
      
      // Check direct API fallback option
      const useDirect = req.query.direct === 'true';
      const command = useDirect 
        ? `bash ${scriptPath} --direct ${domain}`
        : `bash ${scriptPath} ${domain}`;
      
      // Execute command
      const { stdout, stderr } = await execPromise(command);
      
      if (stderr && !stderr.includes('Warning')) {
        throw new Error(stderr);
      }
      
      console.log('DNS setup output:', stdout);
      res.redirect(`/dns?domain=${domain}&success=DNS+setup+completed+successfully`);
    } catch (error) {
      console.error('Error in DNS setup:', error);
      res.redirect(`/dns?domain=${domain}&error=DNS+setup+failed:+${encodeURIComponent(error.message)}`);
    }
  },
  
  // Generate DKIM keys for a domain
  generateDkim: async (req, res) => {
    const { domain } = req.params;
    
    if (!domain) {
      return res.redirect('/dns?error=Domain+is+required');
    }
    
    try {
      // Call the API to generate DKIM keys
      await axios.post(`${API_URL}/api/dns/${domain}/dkim`);
      
      res.redirect(`/dns?domain=${domain}&success=DKIM+keys+generated+successfully`);
    } catch (error) {
      console.error('Error generating DKIM keys:', error);
      res.redirect(`/dns?domain=${domain}&error=Failed+to+generate+DKIM+keys`);
    }
  }
};

module.exports = dnsController;
