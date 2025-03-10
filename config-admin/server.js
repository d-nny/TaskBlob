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
  password: process.env.POSTGRES_PASSWORD,
  port: 5432,
});

// Check if user is authenticated
const isAuthenticated = (req, res, next) => {
  if (req.session.user) {
    return next();
  }
  res.redirect('/login');
};

// Root route - redirect to dashboard or login
app.get('/', (req, res) => {
  if (req.session.user) {
    res.redirect('/dashboard');
  } else {
    res.redirect('/login');
  }
});

// Login page
app.get('/login', (req, res) => {
  res.render('login', { error: null });
});

app.post('/login', async (req, res) => {
  const { username, password } = req.body;
  
  try {
    // In a real application, you'd validate against database
    // For demo, we're using environment variables or defaults
    const adminUser = process.env.ADMIN_USER || 'admin';
    const adminPass = process.env.ADMIN_PASSWORD || 'changeme!';
    
    if (username === adminUser && password === adminPass) {
      req.session.user = { username };
      return res.redirect('/dashboard');
    }
    
    res.render('login', { error: 'Invalid username or password' });
  } catch (error) {
    console.error('Login error:', error);
    res.render('login', { error: 'An error occurred during login' });
  }
});

// Dashboard
app.get('/dashboard', isAuthenticated, async (req, res) => {
  try {
    // Get mail domains
    const domains = await pool.query('SELECT * FROM mail_domains');
    
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
    
    // Run DNS update script
    exec(`/var/server/DNSupdate ${domain}`, (error) => {
      if (error) {
        console.error(`DNS update error: ${error}`);
        return res.redirect('/domains?error=DNS+update+failed');
      }
      
      // Generate DKIM keys
      exec(`/var/server/scripts/generate-dkim.sh ${domain}`, (error) => {
        if (error) {
          console.error(`DKIM generation error: ${error}`);
          return res.redirect('/domains?error=DKIM+generation+failed+but+domain+added');
        }
        
        res.redirect('/domains?success=Domain+added+successfully');
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
  exec('ls -la /var/server/SSL', (error, stdout) => {
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

app.post('/certificates/renew/:domain', isAuthenticated, (req, res) => {
  const { domain } = req.params;
  
  exec(`/var/server/scripts/renew-ssl.sh ${domain}`, (error) => {
    if (error) {
      return res.redirect('/certificates?error=Failed+to+renew+certificate');
    }
    res.redirect('/certificates?success=Certificate+renewed');
  });
});

// Logs viewer
app.get('/logs', isAuthenticated, (req, res) => {
  const logFile = req.query.file || 'mail';
  
  exec(`tail -n 100 /var/log/${logFile}.log`, (error, stdout) => {
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

// Import DNS Controller
const dnsController = require('./controllers/dnsController');

// DNS Management Routes
app.get('/dns', isAuthenticated, dnsController.showDnsConfig);
app.get('/dns/:domain/update', isAuthenticated, dnsController.updateDnsConfig);
app.get('/dns/:domain/setup', isAuthenticated, dnsController.setupDns);
app.get('/dns/:domain/dkim', isAuthenticated, dnsController.generateDkim);

// Add link to DNS management in the navigation menu
// This would be in your header.ejs file - you'd need to update it to include:
// <li class="nav-item">
//   <a class="nav-link" href="/dns">DNS Management</a>
// </li>

// Logout
app.get('/logout', (req, res) => {
  req.session.destroy();
  res.redirect('/login');
});

// Create the views and public directories if they don't exist
const viewsDir = path.join(__dirname, 'views');
const publicDir = path.join(__dirname, 'public');

if (!fs.existsSync(viewsDir)) {
  fs.mkdirSync(viewsDir, { recursive: true });
}

if (!fs.existsSync(publicDir)) {
  fs.mkdirSync(publicDir, { recursive: true });
}

// Start the server
app.listen(PORT, () => {
  console.log(`Admin server running on port ${PORT}`);
});
