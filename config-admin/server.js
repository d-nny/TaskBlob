require('dotenv').config();
const express = require('express');
const bodyParser = require('body-parser');
const path = require('path');
const session = require('express-session');
const bcrypt = require('bcrypt');
const { Pool } = require('pg');
const axios = require('axios');
const fs = require('fs');
const { exec } = require('child_process');

const app = express();
const PORT = process.env.ADMIN_PORT || 3001;

// Parse JSON and URL-encoded bodies
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));

// Set up EJS as the view engine
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

// Create the views and public directories if they don't exist
const viewsDir = path.join(__dirname, 'views');
const publicDir = path.join(__dirname, 'public');

if (!fs.existsSync(viewsDir)) {
  fs.mkdirSync(viewsDir, { recursive: true });
}

if (!fs.existsSync(publicDir)) {
  fs.mkdirSync(publicDir, { recursive: true });
}

// Serve static files
app.use(express.static(path.join(__dirname, 'public')));

// Session configuration
app.use(session({
  secret: process.env.SESSION_SECRET || 'secure_admin_secret_key',
  resave: false,
  saveUninitialized: true,
  cookie: { secure: process.env.NODE_ENV === 'production', maxAge: 3600000 } // 1 hour
}));

// Database connection
const pool = new Pool({
  user: process.env.POSTGRES_USER || 'postgres',
  host: process.env.POSTGRES_HOST || 'postgres',
  database: process.env.POSTGRES_DB || 'postgres',
  password: process.env.POSTGRES_PASSWORD || 'postgres',
  port: 5432,
});

// System state tracking
let systemInitialized = false;
const firstTimeSetup = process.env.FIRST_TIME_SETUP === 'true';

// Initialize database tables
async function initDatabase() {
  try {
    // Check if AdminUsers table exists
    const tableCheck = await pool.query(
      "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'AdminUsers');"
    );
    
    // Create table if it doesn't exist
    if (!tableCheck.rows[0].exists) {
      console.log('Creating AdminUsers table...');
      await pool.query(`
        CREATE TABLE "AdminUsers" (
          "username" VARCHAR(255) PRIMARY KEY,
          "password" VARCHAR(255) NOT NULL,
          "isActive" BOOLEAN DEFAULT true,
          "createdAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
          "updatedAt" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
      `);
    }
    
    // Create or update admin user with default credentials from env
    const adminUser = process.env.ADMIN_USER || 'admin';
    const adminPass = process.env.ADMIN_PASSWORD || 'FFf3t5h5aJBnTd';
    
    await pool.query(`
      INSERT INTO "AdminUsers" ("username", "password", "isActive")
      VALUES ($1, $2, true)
      ON CONFLICT ("username") DO UPDATE 
      SET "password" = $2, "isActive" = true, "updatedAt" = CURRENT_TIMESTAMP;
    `, [adminUser, adminPass]);
    
    console.log('Admin user created/updated successfully!');
    
    // Check if system is already initialized
    const settingsCheck = await pool.query(
      "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'system_settings');"
    );
    
    if (!settingsCheck.rows[0].exists) {
      // Create system_settings table
      await pool.query(`
        CREATE TABLE "system_settings" (
          "key" VARCHAR(255) PRIMARY KEY,
          "value" TEXT,
          "updated_at" TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
      `);
      
      // Add initialization flag
      await pool.query(`
        INSERT INTO "system_settings" ("key", "value")
        VALUES ('system_initialized', 'false');
      `);
      
      console.log('System settings table created');
    } else {
      // Check if system is initialized
      const initResult = await pool.query(`
        SELECT value FROM "system_settings" WHERE "key" = 'system_initialized';
      `);
      
      if (initResult.rows.length > 0 && initResult.rows[0].value === 'true') {
        systemInitialized = true;
        console.log('System already initialized');
      }
    }
  } catch (error) {
    console.error('Database initialization error:', error);
  }
}

// Initialize database at startup
initDatabase().catch(console.error);

// Check if user is authenticated
const isAuthenticated = (req, res, next) => {
  if (req.session.user) {
    return next();
  }
  res.redirect('/login');
};

// Root route - redirect to dashboard, setup wizard, or login
app.get('/', (req, res) => {
  if (!req.session.user) {
    return res.redirect('/login');
  }
  
  // If system is not initialized and first time setup is enabled
  if (!systemInitialized && firstTimeSetup) {
    return res.redirect('/setup');
  }
  
  res.redirect('/dashboard');
});

// Login page
app.get('/login', (req, res) => {
  res.render('login', { error: null });
});

app.post('/login', async (req, res) => {
  const { username, password } = req.body;
  
  try {
    // First try database authentication
    const result = await pool.query('SELECT * FROM "AdminUsers" WHERE username = $1 AND "isActive" = true', [username]);
    
    if (result.rows.length > 0) {
      const user = result.rows[0];
      // Direct password comparison (not hashed for simplicity)
      if (password === user.password) {
        req.session.user = { username: user.username };
        
        // Check if system is initialized
        const initResult = await pool.query(`
          SELECT value FROM "system_settings" WHERE "key" = 'system_initialized';
        `);
        
        systemInitialized = (initResult.rows.length > 0 && initResult.rows[0].value === 'true');
        
        // Redirect based on system state
        if (!systemInitialized && firstTimeSetup) {
          return res.redirect('/setup');
        }
        
        return res.redirect('/dashboard');
      }
    }
    
    // Fall back to environment variables as backup
    const adminUser = process.env.ADMIN_USER || 'admin';
    const adminPass = process.env.ADMIN_PASSWORD || 'FFf3t5h5aJBnTd';
    
    if (username === adminUser && password === adminPass) {
      req.session.user = { username };
      
      // Check if system is initialized
      const initResult = await pool.query(`
        SELECT value FROM "system_settings" WHERE "key" = 'system_initialized';
      `).catch(() => ({ rows: [] })); // Handle case where table doesn't exist yet
      
      systemInitialized = (initResult.rows.length > 0 && initResult.rows[0].value === 'true');
      
      // Redirect based on system state
      if (!systemInitialized && firstTimeSetup) {
        return res.redirect('/setup');
      }
      
      return res.redirect('/dashboard');
    }
    
    res.render('login', { error: 'Invalid username or password' });
  } catch (error) {
    console.error('Login error:', error);
    res.render('login', { error: 'An error occurred during login' });
  }
});

// Setup wizard routes
app.get('/setup', isAuthenticated, async (req, res) => {
  try {
    // Check if system is already initialized
    const initResult = await pool.query(`
      SELECT value FROM "system_settings" WHERE "key" = 'system_initialized';
    `).catch(() => ({ rows: [] }));
    
    if (initResult.rows.length > 0 && initResult.rows[0].value === 'true') {
      // System already initialized, redirect to dashboard
      return res.redirect('/dashboard');
    }
    
    // Render setup wizard
    res.render('setup', {
      step: req.query.step || 1,
      formData: {},
      error: null
    });
  } catch (error) {
    console.error('Setup error:', error);
    res.render('setup', {
      step: 1,
      formData: {},
      error: 'An error occurred loading the setup wizard'
    });
  }
});

// Setup step processing
app.post('/setup/step/:step', isAuthenticated, async (req, res) => {
  const step = parseInt(req.params.step);
  const formData = req.body;
  
  try {
    switch (step) {
      case 1: // Admin password setup
        // Update admin password
        const { newPassword, confirmPassword } = formData;
        
        if (newPassword !== confirmPassword) {
          return res.render('setup', {
            step: 1,
            formData,
            error: 'Passwords do not match'
          });
        }
        
        // Update admin user password
        await pool.query(`
          UPDATE "AdminUsers"
          SET "password" = $1, "updatedAt" = CURRENT_TIMESTAMP
          WHERE "username" = $2;
        `, [newPassword, req.session.user.username]);
        
        // Store new password in session temporarily
        req.session.setupData = { adminPassword: newPassword };
        
        // Move to next step
        return res.redirect('/setup?step=2');
      
      case 2: // DNS configuration
        // Store domain settings
        const { domain, cloudflareEmail, cloudflareApiKey } = formData;
        
        // Validate required fields
        if (!domain || !cloudflareEmail || !cloudflareApiKey) {
          return res.render('setup', {
            step: 2,
            formData,
            error: 'All fields are required'
          });
        }
        
        // Store DNS settings
        req.session.setupData = {
          ...req.session.setupData,
          domain,
          cloudflareEmail,
          cloudflareApiKey
        };
        
        // Move to next step
        return res.redirect('/setup?step=3');
      
      case 3: // Database schema setup
        // Initialize all required database tables
        
        // Create mail_domains table if it doesn't exist
        await pool.query(`
          CREATE TABLE IF NOT EXISTS "mail_domains" (
            "id" SERIAL PRIMARY KEY,
            "domain" VARCHAR(255) NOT NULL UNIQUE,
            "description" TEXT,
            "active" BOOLEAN DEFAULT true,
            "created_at" TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            "updated_at" TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
          );
        `);
        
        // Create mail_users table if it doesn't exist
        await pool.query(`
          CREATE TABLE IF NOT EXISTS "mail_users" (
            "id" SERIAL PRIMARY KEY,
            "email" VARCHAR(255) NOT NULL UNIQUE,
            "domain_id" INTEGER REFERENCES "mail_domains"("id") ON DELETE CASCADE,
            "password" VARCHAR(255) NOT NULL,
            "quota" INTEGER DEFAULT 1024,
            "active" BOOLEAN DEFAULT true,
            "created_at" TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            "updated_at" TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
          );
        `);
        
        // Create dns_records table if it doesn't exist
        await pool.query(`
          CREATE TABLE IF NOT EXISTS "dns_records" (
            "id" SERIAL PRIMARY KEY,
            "domain" VARCHAR(255) NOT NULL,
            "type" VARCHAR(10) NOT NULL,
            "name" VARCHAR(255) NOT NULL,
            "content" TEXT NOT NULL,
            "ttl" INTEGER DEFAULT 3600,
            "priority" INTEGER,
            "proxied" BOOLEAN DEFAULT false,
            "cf_id" VARCHAR(255),
            "created_at" TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            "updated_at" TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            UNIQUE("domain", "type", "name")
          );
        `);
        
        // Create initial domain record from setup data if provided
        if (req.session.setupData && req.session.setupData.domain) {
          await pool.query(`
            INSERT INTO "mail_domains" ("domain", "description")
            VALUES ($1, 'Primary domain - created during setup')
            ON CONFLICT ("domain") DO NOTHING;
          `, [req.session.setupData.domain]);
        }
        
        // Create settings in environment
        if (req.session.setupData) {
          // Update .env file with setup data
          try {
            const envPath = path.join(__dirname, '..', '.env');
            let envContent = '';
            
            // Read existing .env if it exists
            if (fs.existsSync(envPath)) {
              envContent = fs.readFileSync(envPath, 'utf8');
            }
            
            // Update or add settings
            const updateEnvVar = (name, value) => {
              const regex = new RegExp(`^${name}=.*$`, 'm');
              if (regex.test(envContent)) {
                // Update existing value
                envContent = envContent.replace(regex, `${name}=${value}`);
              } else {
                // Add new value
                envContent += `\n${name}=${value}`;
              }
            };
            
            // Update environment variables
            if (req.session.setupData.domain) {
              updateEnvVar('DOMAIN', req.session.setupData.domain);
            }
            if (req.session.setupData.cloudflareEmail) {
              updateEnvVar('CLOUDFLARE_EMAIL', req.session.setupData.cloudflareEmail);
            }
            if (req.session.setupData.cloudflareApiKey) {
              updateEnvVar('CLOUDFLARE_API_KEY', req.session.setupData.cloudflareApiKey);
            }
            if (req.session.setupData.adminPassword) {
              updateEnvVar('ADMIN_PASSWORD', req.session.setupData.adminPassword);
            }
            
            // Write updated .env file
            fs.writeFileSync(envPath, envContent);
            
            console.log('Environment variables updated');
          } catch (error) {
            console.error('Error updating .env file:', error);
          }
        }
        
        // Mark system as initialized
        await pool.query(`
          UPDATE "system_settings"
          SET "value" = 'true', "updated_at" = CURRENT_TIMESTAMP
          WHERE "key" = 'system_initialized';
        `);
        
        systemInitialized = true;
        
        // Remove setup data from session
        delete req.session.setupData;
        
        // Redirect to completion step
        return res.redirect('/setup?step=4');
      
      case 4: // Setup completion
        // Just render the completion page
        return res.render('setup', {
          step: 4,
          completed: true,
          error: null
        });
      
      default:
        // Invalid step, redirect to first step
        return res.redirect('/setup');
    }
  } catch (error) {
    console.error(`Setup step ${step} error:`, error);
    res.render('setup', {
      step,
      formData,
      error: `An error occurred processing step ${step}`
    });
  }
});

// Dashboard
app.get('/dashboard', isAuthenticated, async (req, res) => {
  try {
    // If system not initialized and first time setup enabled, redirect to setup
    if (!systemInitialized && firstTimeSetup) {
      return res.redirect('/setup');
    }
    
    // Get mail domains
    const domains = await pool.query('SELECT * FROM mail_domains').catch(() => ({ rows: [] }));
    
    // Get server stats
    exec('df -h | grep /dev/sda1', (error, stdout) => {
      const diskUsage = error ? 'Unknown' : stdout.trim();
      
      exec('free -h', (error, stdout) => {
        const memoryUsage = error ? 'Unknown' : stdout.trim();
        
        res.render('dashboard', {
          user: req.session.user,
          domains: domains.rows,
          diskUsage,
          memoryUsage
        });
      });
    });
  } catch (error) {
    console.error('Dashboard error:', error);
    res.render('dashboard', {
      user: req.session.user,
      domains: [],
      diskUsage: 'Error fetching',
      memoryUsage: 'Error fetching',
      error: 'Failed to load dashboard data'
    });
  }
});

// Domain management routes
app.get('/domains', isAuthenticated, async (req, res) => {
  try {
    const domains = await pool.query('SELECT * FROM mail_domains');
    res.render('domains', { domains: domains.rows, success: req.query.success, error: req.query.error });
  } catch (error) {
    console.error('Domains list error:', error);
    res.render('domains', { domains: [], error: 'Failed to load domains' });
  }
});

app.get('/domains/add', isAuthenticated, (req, res) => {
  res.render('domain-form', { domain: null, action: 'add' });
});

app.post('/domains/add', isAuthenticated, async (req, res) => {
  const { domain, description } = req.body;
  
  try {
    // Insert domain into database
    await pool.query(
      'INSERT INTO mail_domains (domain, description) VALUES ($1, $2)',
      [domain, description]
    );
    
    // Run DNS update script if it exists
    const dnsScript = '/var/server/DNSupdate';
    fs.access(dnsScript, fs.constants.X_OK, (err) => {
      if (err) {
        console.log('DNS update script not found or not executable. Skipping DNS update.');
        return res.redirect('/domains?success=Domain+added+successfully+without+DNS+update');
      }
      
      exec(`${dnsScript} ${domain}`, (error) => {
        if (error) {
          console.error(`DNS update error: ${error}`);
          return res.redirect('/domains?error=DNS+update+failed');
        }
        
        // Generate DKIM keys if script exists
        const dkimScript = path.join(__dirname, '..', 'dns', 'generate-dkim.sh');
        fs.access(dkimScript, fs.constants.X_OK, (err) => {
          if (err) {
            console.log('DKIM generation script not found or not executable. Skipping DKIM generation.');
            return res.redirect('/domains?success=Domain+added+successfully+without+DKIM');
          }
          
          exec(`${dkimScript} ${domain}`, (error) => {
            if (error) {
              console.error(`DKIM generation error: ${error}`);
              return res.redirect('/domains?error=DKIM+generation+failed+but+domain+added');
            }
            
            res.redirect('/domains?success=Domain+added+successfully');
          });
        });
      });
    });
  } catch (error) {
    console.error('Domain add error:', error);
    res.redirect('/domains?error=Failed+to+add+domain');
  }
});

// Email accounts management
app.get('/accounts', isAuthenticated, async (req, res) => {
  try {
    const accounts = await pool.query(`
      SELECT a.*, d.domain 
      FROM mail_users a 
      JOIN mail_domains d ON a.domain_id = d.id
    `);
    res.render('accounts', { accounts: accounts.rows });
  } catch (error) {
    console.error('Accounts list error:', error);
    res.render('accounts', { accounts: [], error: 'Failed to load accounts' });
  }
});

app.get('/accounts/add', isAuthenticated, async (req, res) => {
  try {
    const domains = await pool.query('SELECT * FROM mail_domains');
    res.render('account-form', { domains: domains.rows, account: null, action: 'add' });
  } catch (error) {
    console.error('Account form error:', error);
    res.render('account-form', { domains: [], error: 'Failed to load domains' });
  }
});

app.post('/accounts/add', isAuthenticated, async (req, res) => {
  const { email, domain_id, password, quota } = req.body;
  
  try {
    // Hash password
    const hashedPassword = await bcrypt.hash(password, 10);
    
    // Insert account
    await pool.query(
      'INSERT INTO mail_users (email, domain_id, password, quota) VALUES ($1, $2, $3, $4)',
      [email, domain_id, hashedPassword, quota || 1024]
    );
    
    res.redirect('/accounts?success=Account+added+successfully');
  } catch (error) {
    console.error('Account add error:', error);
    res.redirect('/accounts?error=Failed+to+add+account');
  }
});

// SSL certificate management
app.get('/certificates', isAuthenticated, (req, res) => {
  const sslDir = '/var/server/SSL';
  
  // Check if SSL directory exists
  fs.access(sslDir, fs.constants.R_OK, (err) => {
    if (err) {
      console.log('SSL directory not found. Using alternative method.');
      
      // Alternative method: check in the local ssl directory
      const localSslDir = path.join(__dirname, '..', 'ssl');
      fs.readdir(localSslDir, (err, files) => {
        if (err) {
          return res.render('certificates', { 
            certificates: [],
            error: 'SSL directory not found or not accessible'
          });
        }
        
        const certificates = files
          .filter(file => file.endsWith('.crt') || file.endsWith('.pem'))
          .map(file => file.replace(/\.(crt|pem)$/, ''));
        
        res.render('certificates', { certificates });
      });
      return;
    }
    
    exec(`ls -la ${sslDir}`, (error, stdout) => {
      const certificates = error ? [] : stdout
        .split('\n')
        .filter(line => line.includes('drwx'))
        .map(line => {
          const parts = line.split(/\s+/);
          return parts[parts.length - 1];
        })
        .filter(name => name !== '.' && name !== '..');
      
      res.render('certificates', { certificates });
    });
  });
});

app.post('/certificates/renew/:domain', isAuthenticated, (req, res) => {
  const { domain } = req.params;
  
  // Check if renew script exists
  const renewScript = '/var/server/scripts/renew-ssl.sh';
  fs.access(renewScript, fs.constants.X_OK, (err) => {
    if (err) {
      console.log('SSL renewal script not found or not executable.');
      return res.redirect('/certificates?error=SSL+renewal+script+not+found');
    }
    
    exec(`${renewScript} ${domain}`, (error) => {
      if (error) {
        return res.redirect('/certificates?error=Failed+to+renew+certificate');
      }
      res.redirect('/certificates?success=Certificate+renewed');
    });
  });
});

// Logs viewer
app.get('/logs', isAuthenticated, (req, res) => {
  const logFile = req.query.file || 'mail';
  const logPath = `/var/log/${logFile}.log`;
  
  // Check if log file exists
  fs.access(logPath, fs.constants.R_OK, (err) => {
    if (err) {
      console.log(`Log file ${logPath} not found or not accessible.`);
      
      // Get a list of available log files
      exec('ls -la /var/log | grep ".log"', (error, stdout) => {
        const availableLogs = error ? [] : stdout
          .split('\n')
          .filter(Boolean)
          .map(line => {
            const match = line.match(/([a-zA-Z0-9_-]+)\.log/);
            return match ? match[1] : null;
          })
          .filter(Boolean);
        
        res.render('logs', { 
          logContent: 'Log file not found or not accessible',
          logFile,
          availableLogs
        });
      });
      return;
    }
    
    exec(`tail -n 100 ${logPath}`, (error, stdout) => {
      const logContent = error ? 'Error reading log file' : stdout;
      
      exec('ls -la /var/log | grep ".log"', (error, stdout) => {
        const availableLogs = error ? [] : stdout
          .split('\n')
          .filter(Boolean)
          .map(line => {
            const match = line.match(/([a-zA-Z0-9_-]+)\.log/);
            return match ? match[1] : null;
          })
          .filter(Boolean);
        
        res.render('logs', { logContent, logFile, availableLogs });
      });
    });
  });
});

// Import DNS Controller
const dnsController = require('./controllers/dnsController');

// DNS Management Routes
app.get('/dns', isAuthenticated, dnsController.showDnsConfig);
app.get('/dns/:domain/update', isAuthenticated, dnsController.updateDnsConfig);
app.get('/dns/:domain/setup', isAuthenticated, dnsController.setupDns);
app.get('/dns/:domain/dkim', isAuthenticated, dnsController.generateDkim);

// System settings
app.get('/settings', isAuthenticated, async (req, res) => {
  try {
    // Get system settings
    const settingsQuery = await pool.query('SELECT * FROM system_settings').catch(() => ({ rows: [] }));
    const settings = {};
    
    // Convert rows to key-value pairs
    settingsQuery.rows.forEach(row => {
      settings[row.key] = row.value;
    });
    
    res.render('settings', { 
      settings,
      success: req.query.success,
      error: req.query.error
    });
  } catch (error) {
    console.error('Settings error:', error);
    res.render('settings', { 
      settings: {},
      error: 'Failed to load settings'
    });
  }
});

app.post('/settings/update', isAuthenticated, async (req, res) => {
  try {
    // Update settings from form
    for (const [key, value] of Object.entries(req.body)) {
      if (key.startsWith('setting_')) {
        const settingKey = key.replace('setting_', '');
        
        await pool.query(`
          INSERT INTO system_settings ("key", "value", "updated_at")
          VALUES ($1, $2, CURRENT_TIMESTAMP)
          ON CONFLICT ("key") DO UPDATE
          SET "value" = $2, "updated_at" = CURRENT_TIMESTAMP;
        `, [settingKey, value]);
      }
    }
    
    res.redirect('/settings?success=Settings+updated+successfully');
  } catch (error) {
    console.error('Settings update error:', error);
    res.redirect('/settings?error=Failed+to+update+settings');
  }
});

// Logout
app.get('/logout', (req, res) => {
  req.session.destroy();
  res.redirect('/login');
});

// Start the server
app.listen(PORT, () => {
  console.log(`Admin server running on port ${PORT}`);
});
