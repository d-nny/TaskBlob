const express = require('express');
const { Sequelize, DataTypes } = require('sequelize');
const cors = require('cors');
const morgan = require('morgan');
const helmet = require('helmet');
const winston = require('winston');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const { promisify } = require('util');
const execAsync = promisify(exec);
const https = require('https');

// Initialize Express app
const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(express.json());
app.use(cors());
app.use(morgan('dev'));
app.use(helmet());

// Configure logger
const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json()
  ),
  transports: [
    new winston.transports.File({ filename: 'error.log', level: 'error' }),
    new winston.transports.File({ filename: 'combined.log' }),
    new winston.transports.Console({
      format: winston.format.combine(
        winston.format.colorize(),
        winston.format.simple()
      )
    })
  ]
});

// Configure PostgreSQL connection
const sequelize = new Sequelize(
  process.env.POSTGRES_DB || 'config',
  process.env.POSTGRES_USER || 'postgres',
  process.env.POSTGRES_PASSWORD || 'postgres',
  {
    host: process.env.POSTGRES_HOST || 'postgres',
    dialect: 'postgres',
    logging: msg => logger.debug(msg)
  }
);

// Define DNS Configuration model
const DNSConfig = sequelize.define('DNSConfig', {
  domain: {
    type: DataTypes.STRING,
    primaryKey: true,
    allowNull: false,
    unique: true
  },
  config: {
    type: DataTypes.JSONB,
    allowNull: false
  },
  lastUpdated: {
    type: DataTypes.DATE,
    defaultValue: DataTypes.NOW
  },
  active: {
    type: DataTypes.BOOLEAN,
    defaultValue: true
  }
});

// Define DomainSettings model
const DomainSettings = sequelize.define('DomainSettings', {
  domain: {
    type: DataTypes.STRING,
    primaryKey: true,
    allowNull: false,
    unique: true
  },
  dkimEnabled: {
    type: DataTypes.BOOLEAN,
    defaultValue: true
  },
  spfRecord: {
    type: DataTypes.STRING,
    allowNull: true
  },
  dmarcPolicy: {
    type: DataTypes.ENUM('none', 'quarantine', 'reject'),
    defaultValue: 'none'
  },
  dmarcPercentage: {
    type: DataTypes.INTEGER,
    defaultValue: 100
  },
  dmarcReportEmail: {
    type: DataTypes.STRING,
    allowNull: true
  }
});

// Define CloudflareAPI model
const CloudflareAPI = sequelize.define('CloudflareAPI', {
  id: {
    type: DataTypes.INTEGER,
    primaryKey: true,
    autoIncrement: true
  },
  email: {
    type: DataTypes.STRING,
    allowNull: false
  },
  apiKey: {
    type: DataTypes.STRING,
    allowNull: false
  },
  active: {
    type: DataTypes.BOOLEAN,
    defaultValue: true
  }
});

// Define MailUser model (complementary to DBMail)
const MailUser = sequelize.define('MailUser', {
  email: {
    type: DataTypes.STRING,
    primaryKey: true,
    allowNull: false,
    unique: true
  },
  domain: {
    type: DataTypes.STRING,
    allowNull: false
  },
  password: {
    type: DataTypes.STRING,
    allowNull: false
  },
  quota: {
    type: DataTypes.BIGINT,
    defaultValue: 104857600 // 100MB
  },
  active: {
    type: DataTypes.BOOLEAN,
    defaultValue: true
  }
});

// Define MailDomain model (complementary to DBMail)
const MailDomain = sequelize.define('MailDomain', {
  domain: {
    type: DataTypes.STRING,
    primaryKey: true,
    allowNull: false,
    unique: true
  },
  description: {
    type: DataTypes.STRING,
    allowNull: true
  },
  active: {
    type: DataTypes.BOOLEAN,
    defaultValue: true
  }
});

// Initialize database
async function initDatabase() {
  try {
    await sequelize.authenticate();
    logger.info('Database connection established');
    
    await sequelize.sync({ alter: true });
    logger.info('Database models synchronized');
    
    // Check if Cloudflare API credentials are stored
    const apiCredentials = await CloudflareAPI.findOne({ where: { active: true } });
    if (!apiCredentials && process.env.CLOUDFLARE_EMAIL && process.env.CLOUDFLARE_API_KEY) {
      await CloudflareAPI.create({
        email: process.env.CLOUDFLARE_EMAIL,
        apiKey: process.env.CLOUDFLARE_API_KEY,
        active: true
      });
      logger.info('Cloudflare API credentials stored');
    }
  } catch (error) {
    logger.error('Database initialization error:', error);
  }
}

// Cloudflare API helpers
class CloudflareClient {
  constructor(email, apiKey) {
    this.email = email;
    this.apiKey = apiKey;
    this.baseUrl = 'https://api.cloudflare.com/client/v4';
  }

  async request(endpoint, method = 'GET', data = null) {
    return new Promise((resolve, reject) => {
      const options = {
        hostname: 'api.cloudflare.com',
        path: `/client/v4${endpoint}`,
        method: method,
        headers: {
          'Content-Type': 'application/json',
          'X-Auth-Email': this.email,
          'X-Auth-Key': this.apiKey
        }
      };

      const req = https.request(options, (res) => {
        let responseData = '';
        
        res.on('data', (chunk) => {
          responseData += chunk;
        });
        
        res.on('end', () => {
          try {
            const parsedData = JSON.parse(responseData);
            resolve(parsedData);
          } catch (error) {
            reject(new Error(`Failed to parse response: ${error.message}`));
          }
        });
      });
      
      req.on('error', (error) => {
        reject(error);
      });
      
      if (data) {
        req.write(JSON.stringify(data));
      }
      
      req.end();
    });
  }

  async getZoneId(domain) {
    try {
      // Extract root domain from subdomain
      const rootDomain = domain.split('.').slice(-2).join('.');
      const response = await this.request(`/zones?name=${rootDomain}`);
      
      if (!response.success || !response.result || response.result.length === 0) {
        throw new Error(`Zone not found for domain: ${rootDomain}`);
      }
      
      return response.result[0].id;
    } catch (error) {
      logger.error(`Failed to get zone ID for ${domain}:`, error);
      throw error;
    }
  }
  
  async listRecords(zoneId) {
    try {
      const response = await this.request(`/zones/${zoneId}/dns_records`);
      
      if (!response.success) {
        throw new Error(`Failed to list DNS records: ${JSON.stringify(response.errors)}`);
      }
      
      return response.result;
    } catch (error) {
      logger.error(`Failed to list DNS records:`, error);
      throw error;
    }
  }
  
  async createRecord(zoneId, record) {
    try {
      const response = await this.request(
        `/zones/${zoneId}/dns_records`, 
        'POST', 
        record
      );
      
      if (!response.success) {
        throw new Error(`Failed to create DNS record: ${JSON.stringify(response.errors)}`);
      }
      
      return response.result;
    } catch (error) {
      logger.error(`Failed to create DNS record:`, error);
      throw error;
    }
  }
  
  async updateRecord(zoneId, recordId, record) {
    try {
      const response = await this.request(
        `/zones/${zoneId}/dns_records/${recordId}`, 
        'PUT', 
        record
      );
      
      if (!response.success) {
        throw new Error(`Failed to update DNS record: ${JSON.stringify(response.errors)}`);
      }
      
      return response.result;
    } catch (error) {
      logger.error(`Failed to update DNS record:`, error);
      throw error;
    }
  }
  
  async deleteRecord(zoneId, recordId) {
    try {
      const response = await this.request(
        `/zones/${zoneId}/dns_records/${recordId}`, 
        'DELETE'
      );
      
      if (!response.success) {
        throw new Error(`Failed to delete DNS record: ${JSON.stringify(response.errors)}`);
      }
      
      return response.result;
    } catch (error) {
      logger.error(`Failed to delete DNS record:`, error);
      throw error;
    }
  }
}

// Function to transform DNS config into Cloudflare records
function transformDnsConfig(domain, config) {
  const records = [];
  
  // Process A records
  if (config.records && config.records.a) {
    for (const record of config.records.a) {
      records.push({
        type: 'A',
        name: record.name || '@',
        content: record.content,
        ttl: record.ttl || 1, // Auto
        proxied: record.proxied === true
      });
    }
  }
  
  // Process MX records
  if (config.records && config.records.mx) {
    for (const record of config.records.mx) {
      records.push({
        type: 'MX',
        name: record.name || '@',
        content: record.content,
        priority: record.priority || 10,
        ttl: record.ttl || 1
      });
    }
  }
  
  // Process TXT records
  if (config.records && config.records.txt) {
    for (const record of config.records.txt) {
      records.push({
        type: 'TXT',
        name: record.name || '@',
        content: record.content,
        ttl: record.ttl || 1
      });
    }
  }
  
  // Process SRV records
  if (config.records && config.records.srv) {
    for (const record of config.records.srv) {
      records.push({
        type: 'SRV',
        name: record.name,
        data: {
          service: record.service,
          proto: record.proto,
          name: record.target || '@',
          priority: record.priority || 0,
          weight: record.weight || 1,
          port: record.port,
          target: record.target
        },
        ttl: record.ttl || 1
      });
    }
  }
  
  return records;
}

// API Routes

// DNS Configuration routes
app.get('/api/dns', async (req, res) => {
  try {
    const configs = await DNSConfig.findAll();
    res.json(configs);
  } catch (error) {
    logger.error('Error fetching DNS configs:', error);
    res.status(500).json({ error: 'Failed to fetch DNS configurations' });
  }
});

app.get('/api/dns/:domain', async (req, res) => {
  try {
    const config = await DNSConfig.findByPk(req.params.domain);
    if (!config) {
      return res.status(404).json({ error: 'DNS configuration not found' });
    }
    res.json(config);
  } catch (error) {
    logger.error(`Error fetching DNS config for ${req.params.domain}:`, error);
    res.status(500).json({ error: 'Failed to fetch DNS configuration' });
  }
});

app.post('/api/dns', async (req, res) => {
  try {
    logger.info('DNS configuration request received');
    logger.debug('Request body:', req.body);
    
    const { domain, config } = req.body;
    
    if (!domain || !config) {
      logger.warn('Invalid request: Missing domain or config');
      return res.status(400).json({ error: 'Domain and config are required' });
    }
    
    // Validate database connection before proceeding
    try {
      await sequelize.authenticate();
      logger.info('Database connection is valid');
    } catch (dbError) {
      logger.error('Database connection error:', dbError);
      return res.status(500).json({ 
        error: 'Database connection error', 
        details: dbError.message 
      });
    }
    
    try {
      const [dnsConfig, created] = await DNSConfig.findOrCreate({
        where: { domain },
        defaults: { config, lastUpdated: new Date() }
      });
      
      if (!created) {
        logger.info(`Updating existing DNS config for ${domain}`);
        dnsConfig.config = config;
        dnsConfig.lastUpdated = new Date();
        await dnsConfig.save();
      } else {
        logger.info(`Created new DNS config for ${domain}`);
      }
      
      // Save config to file as backup (useful for debugging)
      try {
        const dnsDir = path.join(__dirname, 'dns');
        if (!fs.existsSync(dnsDir)) {
          fs.mkdirSync(dnsDir, { recursive: true });
        }
        fs.writeFileSync(
          path.join(dnsDir, `${domain}.json`), 
          JSON.stringify(config, null, 2)
        );
        logger.info(`DNS config for ${domain} saved to file`);
      } catch (fileError) {
        logger.warn(`Could not save DNS config to file: ${fileError.message}`);
        // Continue anyway as this is not critical
      }
      
      res.status(created ? 201 : 200).json(dnsConfig);
    } catch (dbOpError) {
      logger.error('Database operation error:', dbOpError);
      return res.status(500).json({ 
        error: 'Database operation failed', 
        details: dbOpError.message 
      });
    }
  } catch (error) {
    logger.error('Error creating/updating DNS config:', error);
    res.status(500).json({ 
      error: 'Failed to create/update DNS configuration',
      details: error.message,
      stack: process.env.NODE_ENV !== 'production' ? error.stack : undefined
    });
  }
});

app.delete('/api/dns/:domain', async (req, res) => {
  try {
    const domain = req.params.domain;
    const deleted = await DNSConfig.destroy({ where: { domain } });
    
    if (!deleted) {
      return res.status(404).json({ error: 'DNS configuration not found' });
    }
    
    res.status(204).end();
  } catch (error) {
    logger.error(`Error deleting DNS config for ${req.params.domain}:`, error);
    res.status(500).json({ error: 'Failed to delete DNS configuration' });
  }
});

// DNS Update endpoint (Cloudflare integration)
app.post('/api/dns/:domain/update', async (req, res) => {
  try {
    const domain = req.params.domain;
    
    // Get DNS configuration
    const dnsConfig = await DNSConfig.findByPk(domain);
    if (!dnsConfig) {
      return res.status(404).json({ error: 'DNS configuration not found' });
    }
    
    // Get Cloudflare credentials
    const credentials = await CloudflareAPI.findOne({ where: { active: true } });
    if (!credentials) {
      return res.status(404).json({ error: 'Cloudflare API credentials not found' });
    }
    
    // Save config to file for backup
    const configPath = path.join('/app/dns', `${domain}.json`);
    fs.writeFileSync(configPath, JSON.stringify(dnsConfig.config, null, 2));
    
    // Initialize Cloudflare client
    const cf = new CloudflareClient(credentials.email, credentials.apiKey);
    
    // Get zone ID
    const zoneId = await cf.getZoneId(domain);
    
    // Transform DNS config to Cloudflare format
    const records = transformDnsConfig(domain, dnsConfig.config);
    
    // Get existing records to compare
    const existingRecords = await cf.listRecords(zoneId);
    
    // Track results
    const results = {
      created: [],
      updated: [],
      deleted: [],
      errors: []
    };
    
    // Process each record
    for (const record of records) {
      try {
        // Look for existing record with same name and type
        const existingRecord = existingRecords.find(
          r => r.name === `${record.name === '@' ? '' : record.name + '.'}${domain}` && 
               r.type === record.type
        );
        
        if (existingRecord) {
          // Update record
          const updatedRecord = await cf.updateRecord(zoneId, existingRecord.id, record);
          results.updated.push(updatedRecord);
        } else {
          // Create new record
          const newRecord = await cf.createRecord(zoneId, record);
          results.created.push(newRecord);
        }
      } catch (error) {
        results.errors.push({
          record,
          error: error.message
        });
      }
    }
    
    res.json({
      success: true,
      message: 'DNS records updated',
      results
    });
  } catch (error) {
    logger.error(`Error updating DNS for ${req.params.domain}:`, error);
    res.status(500).json({ error: `Failed to update DNS: ${error.message}` });
  }
});

// DKIM Key generation
app.post('/api/dns/:domain/dkim', async (req, res) => {
  try {
    const domain = req.params.domain;
    
    // Create a temp script to generate DKIM keys
    const scriptPath = path.join('/tmp', 'generate-dkim.sh');
    const script = `
      #!/bin/bash
      DOMAIN="${domain}"
      SELECTOR="mail"
      DKIM_DIR="/app/dns/dkim/${domain}"
      
      mkdir -p "$DKIM_DIR"
      cd "$DKIM_DIR"
      
      # Generate DKIM keys
      openssl genrsa -out "${SELECTOR}.private" 2048
      openssl rsa -in "${SELECTOR}.private" -pubout -out "${SELECTOR}.public"
      
      # Convert to DNS format
      PUBLIC_KEY=$(cat "${SELECTOR}.public" | grep -v '^-' | tr -d '\\n')
      echo "v=DKIM1; k=rsa; p=$PUBLIC_KEY" > "${SELECTOR}.txt"
      
      # Return the key
      cat "${SELECTOR}.txt"
    `;
    
    fs.writeFileSync(scriptPath, script);
    fs.chmodSync(scriptPath, '755');
    
    // Execute the script
    const { stdout, stderr } = await execAsync(scriptPath);
    if (stderr) {
      logger.error(`DKIM generation error: ${stderr}`);
    }
    
    // Get the DKIM record
    const dkimRecord = stdout.trim();
    
    // Update domain settings
    const [domainSettings, created] = await DomainSettings.findOrCreate({
      where: { domain },
      defaults: { dkimEnabled: true }
    });
    
    // Update the DNS config to include DKIM record
    const dnsConfig = await DNSConfig.findByPk(domain);
    if (dnsConfig) {
      const config = dnsConfig.config;
      
      // Add DKIM record to TXT records
      if (!config.records) {
        config.records = {};
      }
      if (!config.records.txt) {
        config.records.txt = [];
      }
      
      // Remove any existing DKIM record
      config.records.txt = config.records.txt.filter(
        record => !record.name || record.name !== 'mail._domainkey'
      );
      
      // Add the new DKIM record
      config.records.txt.push({
        name: 'mail._domainkey',
        content: dkimRecord,
        proxied: false
      });
      
      dnsConfig.config = config;
      dnsConfig.lastUpdated = new Date();
      await dnsConfig.save();
      
      // Push changes to Cloudflare immediately
      try {
        // Get Cloudflare credentials
        const credentials = await CloudflareAPI.findOne({ where: { active: true } });
        if (credentials) {
          // Initialize Cloudflare client
          const cf = new CloudflareClient(credentials.email, credentials.apiKey);
          
          // Get zone ID
          const zoneId = await cf.getZoneId(domain);
          
          // Get existing records
          const existingRecords = await cf.listRecords(zoneId);
          
          // Find existing DKIM record
          const existingDkim = existingRecords.find(
            r => r.type === 'TXT' && r.name === `mail._domainkey.${domain}`
          );
          
          const dkimData = {
            type: 'TXT',
            name: 'mail._domainkey',
            content: dkimRecord,
            ttl: 1
          };
          
          if (existingDkim) {
            // Update record
            await cf.updateRecord(zoneId, existingDkim.id, dkimData);
          } else {
            // Create new record
            await cf.createRecord(zoneId, dkimData);
          }
          
          logger.info(`DKIM record for ${domain} pushed to Cloudflare`);
        }
      } catch (cfError) {
        logger.error(`Failed to push DKIM record to Cloudflare: ${cfError.message}`);
      }
    }
    
    // Return the DKIM record
    res.json({
      success: true,
      domain,
      dkimRecord,
      dkimSelector: 'mail'
    });
  } catch (error) {
    logger.error(`Error generating DKIM for ${req.params.domain}:`, error);
    res.status(500).json({ error: 'Failed to generate DKIM keys' });
  }
});

// SSL Certificate API (Certbot with DNS validation)
app.post('/api/ssl/:domain/generate', async (req, res) => {
  try {
    const domain = req.params.domain;
    const email = req.body.email || `admin@${domain}`;
    const subdomains = req.body.subdomains || ['mail'];
    
    // Create a temp script to generate SSL certificate using DNS validation
    const scriptPath = path.join('/tmp', 'generate-ssl.sh');
    const script = `
      #!/bin/bash
      DOMAIN="${domain}"
      EMAIL="${email}"
      DOMAINS="${subdomains.map(sub => `${sub}.${domain}`).join(',')}"
      
      # Check if certbot is installed
      if ! command -v certbot &> /dev/null; then
        echo "Installing certbot..."
        apt-get update
        apt-get install -y certbot python3-certbot-dns-cloudflare
      fi
      
      # Create Cloudflare credentials file
      mkdir -p /root/.secrets/certbot/
      cat > /root/.secrets/certbot/cloudflare.ini << EOF
dns_cloudflare_email = ${process.env.CLOUDFLARE_EMAIL}
dns_cloudflare_api_key = ${process.env.CLOUDFLARE_API_KEY}
EOF
      chmod 600 /root/.secrets/certbot/cloudflare.ini
      
      # Run certbot with DNS validation
      certbot certonly --dns-cloudflare \\
        --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \\
        --email $EMAIL \\
        --agree-tos \\
        --no-eff-email \\
        -d $DOMAINS \\
        --keep \\
        --non-interactive
      
      # Create SSL directory for Docker volumes
      mkdir -p /app/ssl/${domain}
      
      # Copy certificates
      cp /etc/letsencrypt/live/${subdomains[0]}.${domain}/fullchain.pem /app/ssl/${domain}/
      cp /etc/letsencrypt/live/${subdomains[0]}.${domain}/privkey.pem /app/ssl/${domain}/
      
      echo "SSL certificate generated and copied to Docker volume"
    `;
    
    fs.writeFileSync(scriptPath, script);
    fs.chmodSync(scriptPath, '755');
    
    // This would need to run with sudo/root privileges
    res.json({
      success: true,
      message: 'SSL certificate generation script created',
      scriptPath,
      note: 'This script must be run with root privileges on the host machine'
    });
  } catch (error) {
    logger.error(`Error creating SSL certificate script for ${req.params.domain}:`, error);
    res.status(500).json({ error: 'Failed to create SSL certificate script' });
  }
});

// Mail domain routes
app.get('/api/mail/domains', async (req, res) => {
  try {
    const domains = await MailDomain.findAll();
    res.json(domains);
  } catch (error) {
    logger.error('Error fetching mail domains:', error);
    res.status(500).json({ error: 'Failed to fetch mail domains' });
  }
});

app.post('/api/mail/domains', async (req, res) => {
  try {
    const { domain, description } = req.body;
    
    if (!domain) {
      return res.status(400).json({ error: 'Domain is required' });
    }
    
    const [mailDomain, created] = await MailDomain.findOrCreate({
      where: { domain },
      defaults: { description, active: true }
    });
    
    if (!created) {
      mailDomain.description = description;
      await mailDomain.save();
    }
    
    res.status(created ? 201 : 200).json(mailDomain);
  } catch (error) {
    logger.error('Error creating/updating mail domain:', error);
    res.status(500).json({ error: 'Failed to create/update mail domain' });
  }
});

app.delete('/api/mail/domains/:domain', async (req, res) => {
  try {
    const domain = req.params.domain;
    const deleted = await MailDomain.destroy({ where: { domain } });
    
    if (!deleted) {
      return res.status(404).json({ error: 'Mail domain not found' });
    }
    
    res.status(204).end();
  } catch (error) {
    logger.error(`Error deleting mail domain ${req.params.domain}:`, error);
    res.status(500).json({ error: 'Failed to delete mail domain' });
  }
});

// Mail user routes
app.get('/api/mail/users', async (req, res) => {
  try {
    const users = await MailUser.findAll({
      attributes: { exclude: ['password'] }
    });
    res.json(users);
  } catch (error) {
    logger.error('Error fetching mail users:', error);
    res.status(500).json({ error: 'Failed to fetch mail users' });
  }
});

app.post('/api/mail/users', async (req, res) => {
  try {
    const { email, domain, password, quota } = req.body;
    
    if (!email || !domain || !password) {
      return res.status(400).json({ error: 'Email, domain, and password are required' });
    }
    
    // Check if domain exists
    const mailDomain = await MailDomain.findByPk(domain);
    if (!mailDomain) {
      return res.status(400).json({ error: 'Domain does not exist' });
    }
    
    // Hash password (in a real implementation, use a proper password hashing library)
    const hashedPassword = password; // TODO: Implement proper hashing
    
    const [mailUser, created] = await MailUser.findOrCreate({
      where: { email },
      defaults: { domain, password: hashedPassword, quota, active: true }
    });
    
    if (!created) {
      mailUser.password = hashedPassword;
      if (quota) mailUser.quota = quota;
      await mailUser.save();
    }
    
    // Don't return the password
    const responseUser = mailUser.toJSON();
    delete responseUser.password;
    
    res.status(created ? 201 : 200).json(responseUser);
  } catch (error) {
    logger.error('Error creating/updating mail user:', error);
    res.status(500).json({ error: 'Failed to create/update mail user' });
  }
});

app.delete('/api/mail/users/:email', async (req, res) => {
  try {
    const email = req.params.email;
    const deleted = await MailUser.destroy({ where: { email } });
    
    if (!deleted) {
      return res.status(404).json({ error: 'Mail user not found' });
    }
    
    res.status(204).end();
  } catch (error) {
    logger.error(`Error deleting mail user ${req.params.email}:`, error);
    res.status(500).json({ error: 'Failed to delete mail user' });
  }
});

// Server status routes
app.get('/api/status', (req, res) => {
  res.json({
    status: 'running',
    version: '1.0.0',
    timestamp: new Date()
  });
});

// Start server
initDatabase().then(() => {
  app.listen(PORT, () => {
    logger.info(`Server running on port ${PORT}`);
  });
});
