#!/bin/bash

# Mail Server Setup Script with PostgreSQL Integration
# Usage: ./setup-mail.sh

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Configuration variables
PRIMARY_IP="136.243.2.232"
MAIL_IP="136.243.2.234"
IPV6_PREFIX="2a01:4f8:211:1c4b"
IPV6_PRIMARY="${IPV6_PREFIX}::1"
IPV6_MAIL="${IPV6_PREFIX}::2"
HOSTNAME=$(hostname -f)
POSTFIX_CONFIG_DIR="/etc/postfix"
DOVECOT_CONFIG_DIR="/etc/dovecot"
SSL_DIR="/var/server/SSL"
POSTFIX_SQL_PASSWORD=$(openssl rand -base64 12)
POSTGRES_PASSWORD=$(cat /root/postgres_credentials.txt | grep "PostgreSQL admin password" | cut -d ":" -f2 | tr -d ' ')

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# Function to setup PostgreSQL database for mail
setup_mail_database() {
    echo -e "${GREEN}Setting up PostgreSQL database for mail server...${NC}"
    
    # Check if PostgreSQL is installed
    if ! command -v psql &> /dev/null; then
        echo -e "${RED}PostgreSQL is not installed. Please install it first.${NC}"
        exit 1
    fi

    # Create mail database and user
    echo "Creating 'data' database and postfix user..."
    su - postgres -c "psql -c \"CREATE DATABASE data;\""
    su - postgres -c "psql -c \"CREATE USER postfix WITH ENCRYPTED PASSWORD '${POSTFIX_SQL_PASSWORD}';\""
    su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE data TO postfix;\""
    
    # Connect to the database and create tables
    echo "Creating mail tables..."
    su - postgres -c "psql -d data -c \"
        CREATE TABLE domains (
            id SERIAL PRIMARY KEY,
            domain VARCHAR(255) NOT NULL UNIQUE,
            description TEXT,
            created TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            active BOOLEAN NOT NULL DEFAULT true
        );
        
        CREATE TABLE mailboxes (
            id SERIAL PRIMARY KEY,
            username VARCHAR(255) NOT NULL UNIQUE,
            domain_id INTEGER REFERENCES domains(id) ON DELETE CASCADE,
            password VARCHAR(255) NOT NULL,
            name VARCHAR(255),
            maildir VARCHAR(255) NOT NULL,
            quota BIGINT NOT NULL DEFAULT 104857600, -- 100MB default quota
            local_part VARCHAR(255) NOT NULL,
            created TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            modified TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            active BOOLEAN NOT NULL DEFAULT true
        );
        
        CREATE TABLE aliases (
            id SERIAL PRIMARY KEY,
            source VARCHAR(255) NOT NULL,
            destination VARCHAR(255) NOT NULL,
            domain_id INTEGER REFERENCES domains(id) ON DELETE CASCADE,
            created TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            modified TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            active BOOLEAN NOT NULL DEFAULT true
        );
        
        CREATE TABLE users (
            id SERIAL PRIMARY KEY,
            username VARCHAR(255) NOT NULL UNIQUE,
            password VARCHAR(255) NOT NULL,
            email VARCHAR(255) REFERENCES mailboxes(username) ON DELETE SET NULL,
            firstname VARCHAR(255),
            lastname VARCHAR(255),
            created TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            modified TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            last_login TIMESTAMP,
            role VARCHAR(50) NOT NULL DEFAULT 'user',
            active BOOLEAN NOT NULL DEFAULT true
        );
        
        CREATE INDEX idx_mailboxes_username ON mailboxes(username);
        CREATE INDEX idx_domains_domain ON domains(domain);
        CREATE INDEX idx_aliases_source ON aliases(source);
        CREATE INDEX idx_users_username ON users(username);
        CREATE INDEX idx_users_email ON users(email);
        
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO postfix;
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO postfix;\""
    
    # Create views for Postfix and Dovecot
    echo "Creating mail views..."
    su - postgres -c "psql -d data -c \"
        CREATE VIEW postfix_mailbox AS
        SELECT username, maildir, local_part || '@' || d.domain as email
        FROM mailboxes m
        JOIN domains d ON m.domain_id = d.id
        WHERE m.active = true AND d.active = true;
        
        CREATE VIEW postfix_virtual_domains AS
        SELECT domain
        FROM domains
        WHERE active = true;
        
        CREATE VIEW postfix_virtual_aliases AS
        SELECT source, destination
        FROM aliases
        WHERE active = true;
        
        GRANT SELECT ON postfix_mailbox TO postfix;
        GRANT SELECT ON postfix_virtual_domains TO postfix;
        GRANT SELECT ON postfix_virtual_aliases TO postfix;\""
    
    # Save database credentials
    echo "Saving database credentials..."
    mkdir -p /etc/postfix/sql
    cat > /etc/postfix/sql/credentials.conf << EOF
user = postfix
password = ${POSTFIX_SQL_PASSWORD}
hosts = localhost
dbname = data
EOF
    chmod 640 /etc/postfix/sql/credentials.conf
    chown root:postfix /etc/postfix/sql/credentials.conf
    
    echo -e "${GREEN}Mail database setup completed.${NC}"
    
    # Save mail database credentials to root folder
    echo "Mail Database Credentials:" > /root/mail_db_credentials.txt
    echo "Database: data" >> /root/mail_db_credentials.txt
    echo "Username: postfix" >> /root/mail_db_credentials.txt
    echo "Password: ${POSTFIX_SQL_PASSWORD}" >> /root/mail_db_credentials.txt
    chmod 600 /root/mail_db_credentials.txt
}

# Function to install and configure Postfix
install_postfix() {
    echo -e "${GREEN}Installing and configuring Postfix...${NC}"
    
    # Pre-configure postfix for non-interactive installation
    debconf-set-selections <<< "postfix postfix/mailname string ${HOSTNAME}"
    debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
    
    # Install Postfix and PostgreSQL adapter
    apt-get update
    apt-get install -y postfix postfix-pgsql libsasl2-modules
    
    # Backup original configuration
    cp ${POSTFIX_CONFIG_DIR}/main.cf ${POSTFIX_CONFIG_DIR}/main.cf.bak
    
    # Configure Postfix main.cf
    cat > ${POSTFIX_CONFIG_DIR}/main.cf << EOF
# Basic Postfix configuration
smtpd_banner = \$myhostname ESMTP \$mail_name
biff = no
append_dot_mydomain = no
readme_directory = no

# TLS parameters
smtpd_tls_cert_file = ${SSL_DIR}/\$myhostname/fullchain.pem
smtpd_tls_key_file = ${SSL_DIR}/\$myhostname/privkey.pem
smtpd_tls_security_level = may
smtp_tls_security_level = may
smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache
smtpd_tls_protocols = !SSLv2, !SSLv3
smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3
smtpd_tls_mandatory_ciphers = high
smtpd_tls_exclude_ciphers = aNULL, RC4
smtpd_tls_auth_only = yes

# Network settings
myhostname = ${HOSTNAME}
mydomain = ${HOSTNAME#*.}
myorigin = \$mydomain
inet_interfaces = ${PRIMARY_IP}, ${MAIL_IP}, ${IPV6_PRIMARY}, ${IPV6_MAIL}, localhost
inet_protocols = all
mydestination = localhost, localhost.localdomain, \$myhostname
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128
mailbox_size_limit = 0
recipient_delimiter = +
message_size_limit = 52428800  # 50MB

# Virtual domains configuration
virtual_mailbox_domains = pgsql:/etc/postfix/sql/virtual_domains.cf
virtual_mailbox_maps = pgsql:/etc/postfix/sql/virtual_mailboxes.cf
virtual_alias_maps = pgsql:/etc/postfix/sql/virtual_aliases.cf

# Delivery settings
virtual_transport = lmtp:unix:private/dovecot-lmtp
mailbox_transport = lmtp:unix:private/dovecot-lmtp
local_transport = lmtp:unix:private/dovecot-lmtp

# SASL Authentication
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain = \$myhostname
broken_sasl_auth_clients = yes

# SMTP restrictions
smtpd_helo_required = yes
disable_vrfy_command = yes
strict_rfc821_envelopes = yes
smtpd_delay_reject = yes
smtpd_helo_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname
smtpd_sender_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_sender, reject_unknown_sender_domain
smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_recipient, reject_unknown_recipient_domain, reject_unauth_destination
smtpd_data_restrictions = reject_unauth_pipelining, permit
smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination

# Additional settings
compatibility_level = 2
EOF
    
    # Configure PostgreSQL lookup tables
    mkdir -p ${POSTFIX_CONFIG_DIR}/sql
    
    # Virtual domains
    cat > ${POSTFIX_CONFIG_DIR}/sql/virtual_domains.cf << EOF
user = postfix
password = ${POSTFIX_SQL_PASSWORD}
hosts = localhost
dbname = data
query = SELECT domain FROM postfix_virtual_domains
EOF
    
    # Virtual mailboxes
    cat > ${POSTFIX_CONFIG_DIR}/sql/virtual_mailboxes.cf << EOF
user = postfix
password = ${POSTFIX_SQL_PASSWORD}
hosts = localhost
dbname = data
query = SELECT maildir FROM postfix_mailbox WHERE username = '%s'
EOF
    
    # Virtual aliases
    cat > ${POSTFIX_CONFIG_DIR}/sql/virtual_aliases.cf << EOF
user = postfix
password = ${POSTFIX_SQL_PASSWORD}
hosts = localhost
dbname = data
query = SELECT destination FROM postfix_virtual_aliases WHERE source = '%s'
EOF
    
    # Set permissions on SQL config files
    chmod 640 ${POSTFIX_CONFIG_DIR}/sql/*.cf
    chown root:postfix ${POSTFIX_CONFIG_DIR}/sql/*.cf
    
    # Configure master.cf for submission and secure SMTP
    cat > ${POSTFIX_CONFIG_DIR}/master.cf << EOF
# ==========================================================================
# service type  private unpriv  chroot  wakeup  maxproc command + args
#               (yes)   (yes)   (no)    (never) (100)
# ==========================================================================
smtp      inet  n       -       y       -       -       smtpd
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
smtps     inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
pickup    unix  n       -       y       60      1       pickup
cleanup   unix  n       -       y       -       0       cleanup
qmgr      unix  n       -       n       300     1       qmgr
tlsmgr    unix  -       -       y       1000?   1       tlsmgr
rewrite   unix  -       -       y       -       -       trivial-rewrite
bounce    unix  -       -       y       -       0       bounce
defer     unix  -       -       y       -       0       bounce
trace     unix  -       -       y       -       0       bounce
verify    unix  -       -       y       -       1       verify
flush     unix  n       -       y       1000?   0       flush
proxymap  unix  -       -       n       -       -       proxymap
proxywrite unix -       -       n       -       1       proxymap
smtp      unix  -       -       y       -       -       smtp
relay     unix  -       -       y       -       -       smtp
showq     unix  n       -       y       -       -       showq
error     unix  -       -       y       -       -       error
retry     unix  -       -       y       -       -       error
discard   unix  -       -       y       -       -       discard
local     unix  -       n       n       -       -       local
virtual   unix  -       n       n       -       -       virtual
lmtp      unix  -       -       y       -       -       lmtp
anvil     unix  -       -       y       -       1       anvil
scache    unix  -       -       y       -       1       scache
EOF
    
    echo -e "${GREEN}Postfix installation and configuration completed.${NC}"
}

# Function to install and configure Dovecot
install_dovecot() {
    echo -e "${GREEN}Installing and configuring Dovecot...${NC}"
    
    # Install Dovecot and PostgreSQL adapter
    apt-get update
    apt-get install -y dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-pgsql
    
    # Create mail directory
    mkdir -p /var/mail/vhosts
    
    # Backup original configuration
    cp -r ${DOVECOT_CONFIG_DIR}/conf.d ${DOVECOT_CONFIG_DIR}/conf.d.bak
    cp ${DOVECOT_CONFIG_DIR}/dovecot.conf ${DOVECOT_CONFIG_DIR}/dovecot.conf.bak
    
    # Configure Dovecot main configuration
    cat > ${DOVECOT_CONFIG_DIR}/dovecot.conf << EOF
# Dovecot configuration file
protocols = imap pop3 lmtp
listen = ${PRIMARY_IP}, ${MAIL_IP}, ${IPV6_PRIMARY}, ${IPV6_MAIL}, localhost

# Base directory where to store runtime data
base_dir = /var/run/dovecot/

# Log settings
log_path = /var/log/dovecot.log
info_log_path = /var/log/dovecot-info.log
debug_log_path = /var/log/dovecot-debug.log

# SSL settings
ssl = required
ssl_cert = <${SSL_DIR}/${HOSTNAME}/fullchain.pem
ssl_key = <${SSL_DIR}/${HOSTNAME}/privkey.pem
ssl_min_protocol = TLSv1.2
ssl_cipher_list = ALL:!ADH:!LOW:!SSLv2:!SSLv3:!EXP:!aNULL:+HIGH:+MEDIUM

# Authentication processes
service auth {
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
    group = vmail
  }
  
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }
  
  user = root
}

# LMTP service for mail delivery
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
  user = vmail
}

# Settings for mail delivery
mail_home = /var/mail/vhosts/%d/%n
mail_location = maildir:~/Maildir
mail_uid = vmail
mail_gid = vmail
first_valid_uid = 1000
last_valid_uid = 1000

# Include all configuration files from conf.d directory
!include conf.d/*.conf
EOF
    
    # Configure 10-auth.conf
    cat > ${DOVECOT_CONFIG_DIR}/conf.d/10-auth.conf << EOF
auth_mechanisms = plain login
!include auth-sql.conf.ext
EOF
    
    # Configure auth-sql.conf.ext
    cat > ${DOVECOT_CONFIG_DIR}/auth-sql.conf.ext << EOF
passdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}

userdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}
EOF
    
    # Configure dovecot-sql.conf.ext
    cat > ${DOVECOT_CONFIG_DIR}/dovecot-sql.conf.ext << EOF
driver = pgsql
connect = host=localhost dbname=data user=postfix password=${POSTFIX_SQL_PASSWORD}
default_pass_scheme = SHA512-CRYPT

# Password query
password_query = SELECT username AS user, password, '/var/mail/vhosts/%d/%n' AS userdb_home, 'maildir:/var/mail/vhosts/%d/%n/Maildir' AS userdb_mail, 1000 AS userdb_uid, 1000 AS userdb_gid FROM mailboxes WHERE username = '%u' AND active = true

# User query
user_query = SELECT '/var/mail/vhosts/%d/%n' AS home, 'maildir:/var/mail/vhosts/%d/%n/Maildir' AS mail, 1000 AS uid, 1000 AS gid, CONCAT('*:bytes=', quota) AS quota_rule FROM mailboxes WHERE username = '%u' AND active = true
EOF
    
    # Configure 10-mail.conf
    cat > ${DOVECOT_CONFIG_DIR}/conf.d/10-mail.conf << EOF
mail_privileged_group = vmail
mail_access_groups = vmail
mail_location = maildir:~/Maildir

namespace inbox {
  inbox = yes
  separator = /
  mailbox Drafts {
    auto = subscribe
    special_use = \Drafts
  }
  mailbox Junk {
    auto = subscribe
    special_use = \Junk
  }
  mailbox Sent {
    auto = subscribe
    special_use = \Sent
  }
  mailbox Trash {
    auto = subscribe
    special_use = \Trash
  }
  mailbox Archive {
    auto = subscribe
    special_use = \Archive
  }
}
EOF
    
    # Create vmail user for mail storage
    groupadd -g 1000 vmail
    useradd -g vmail -u 1000 vmail -d /var/mail
    
    # Set permissions on mail directory
    chown -R vmail:vmail /var/mail
    
    # Set permissions on Dovecot config files
    chmod 640 ${DOVECOT_CONFIG_DIR}/dovecot-sql.conf.ext
    chown root:dovecot ${DOVECOT_CONFIG_DIR}/dovecot-sql.conf.ext
    
    echo -e "${GREEN}Dovecot installation and configuration completed.${NC}"
}

# Function to install SpamAssassin and ClamAV
install_email_security() {
    echo -e "${GREEN}Installing SpamAssassin and ClamAV...${NC}"
    
    # Install packages
    apt-get update
    apt-get install -y spamassassin clamav clamav-daemon amavisd-new
    
    # Enable SpamAssassin
    sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/spamassassin
    
    # Configure Amavis for spam and virus scanning
    cat > /etc/amavis/conf.d/15-content_filter_mode << EOF
use strict;

# Default antivirus checking mode
@bypass_virus_checks_maps = (
   \%bypass_virus_checks, \@bypass_virus_checks_acl, \$bypass_virus_checks_re);

# Default antispam checking mode
@bypass_spam_checks_maps = (
   \%bypass_spam_checks, \@bypass_spam_checks_acl, \$bypass_spam_checks_re);

1;  # ensure a defined return
EOF
    
    # Add Postfix user to clamav group for socket access
    usermod -a -G clamav postfix
    
    # Restart services
    systemctl restart spamassassin
    systemctl restart clamav-daemon
    systemctl restart amavis
    
    echo -e "${GREEN}Email security setup completed.${NC}"
}

# Function to create admin and test user
create_test_accounts() {
    echo -e "${GREEN}Creating admin user and test accounts...${NC}"
    
    # Add domain to database
    local DOMAIN=""
    read -p "Enter your primary mail domain: " DOMAIN
    
    if [ -z "$DOMAIN" ]; then
        echo "No domain provided, using hostname domain"
        DOMAIN=${HOSTNAME#*.}
    fi
    
    echo "Adding domain $DOMAIN to database..."
    su - postgres -c "psql -d data -c \"INSERT INTO domains (domain, description) VALUES ('$DOMAIN', 'Primary domain');\"" || \
    echo "Error adding domain. It may already exist."
    
    # Get domain ID
    DOMAIN_ID=$(su - postgres -c "psql -d data -t -c \"SELECT id FROM domains WHERE domain = '$DOMAIN';\"" | tr -d '[:space:]')
    
    # Create admin mailbox
    ADMIN_PASS=$(openssl rand -base64 12)
    ADMIN_PASS_HASH=$(doveadm pw -s SHA512-CRYPT -p "$ADMIN_PASS")
    
    echo "Creating admin@$DOMAIN mailbox..."
    su - postgres -c "psql -d data -c \"INSERT INTO mailboxes (username, domain_id, password, name, maildir, local_part) VALUES ('admin@$DOMAIN', $DOMAIN_ID, '$ADMIN_PASS_HASH', 'Administrator', '/var/mail/vhosts/$DOMAIN/admin', 'admin');\"" || \
    echo "Error adding admin mailbox. It may already exist."
    
    # Create test mailbox
    TEST_PASS=$(openssl rand -base64 12)
    TEST_PASS_HASH=$(doveadm pw -s SHA512-CRYPT -p "$TEST_PASS")
    
    echo "Creating test@$DOMAIN mailbox..."
    su - postgres -c "psql -d data -c \"INSERT INTO mailboxes (username, domain_id, password, name, maildir, local_part) VALUES ('test@$DOMAIN', $DOMAIN_ID, '$TEST_PASS_HASH', 'Test User', '/var/mail/vhosts/$DOMAIN/test', 'test');\"" || \
    echo "Error adding test mailbox. It may already exist."
    
    # Create admin user for website
    echo "Creating admin user for website login..."
    su - postgres -c "psql -d data -c \"INSERT INTO users (username, password, email, firstname, lastname, role) VALUES ('admin', '$ADMIN_PASS_HASH', 'admin@$DOMAIN', 'Site', 'Administrator', 'admin');\"" || \
    echo "Error adding admin user. It may already exist."
    
    # Create mail directories
    mkdir -p /var/mail/vhosts/$DOMAIN/admin/Maildir/{cur,new,tmp}
    mkdir -p /var/mail/vhosts/$DOMAIN/test/Maildir/{cur,new,tmp}
    chown -R vmail:vmail /var/mail/vhosts/
    
    # Save mail accounts to file
    echo "Mail accounts created:" > /root/mail_accounts.txt
    echo "Domain: $DOMAIN" >> /root/mail_accounts.txt
    echo "Admin account: admin@$DOMAIN / $ADMIN_PASS" >> /root/mail_accounts.txt
    echo "Test account: test@$DOMAIN / $TEST_PASS" >> /root/mail_accounts.txt
    echo "Website admin: admin / $ADMIN_PASS" >> /root/mail_accounts.txt
    chmod 600 /root/mail_accounts.txt
    
    echo -e "${GREEN}Test accounts created and saved to /root/mail_accounts.txt${NC}"
}

# Function to setup webmail (Roundcube)
setup_webmail() {
    echo -e "${GREEN}Setting up Roundcube webmail...${NC}"
    
    # Install required packages
    apt-get update
    apt-get install -y nginx php-fpm php-pgsql php-intl php-json php-gd \
    php-curl php-xml php-mbstring php-zip composer
    
    # Install Roundcube
    apt-get install -y roundcube roundcube-pgsql
    
    # Configure Roundcube database
    RC_DB_PASSWORD=$(openssl rand -base64 12)
    
    # Create Roundcube database
    su - postgres -c "psql -c \"CREATE USER roundcube WITH ENCRYPTED PASSWORD '${RC_DB_PASSWORD}';\""
    su - postgres -c "psql -c \"CREATE DATABASE roundcube OWNER roundcube;\""
    
    # Configure database connection
    sed -i "s/\$config\['db_dsnw'\] = 'mysql:.*/\$config\['db_dsnw'\] = 'pgsql:\/\/roundcube:${RC_DB_PASSWORD}@localhost\/roundcube';/" /etc/roundcube/config.inc.php
    
    # Configure IMAP settings
    sed -i "s/\$config\['default_host'\] = '';/\$config\['default_host'\] = 'localhost';/" /etc/roundcube/config.inc.php
    sed -i "s/\$config\['smtp_server'\] = '';/\$config\['smtp_server'\] = 'localhost';/" /etc/roundcube/config.inc.php
    sed -i "s/\$config\['smtp_port'\] = 25;/\$config\['smtp_port'\] = 587;/" /etc/roundcube/config.inc.php
    sed -i "s/\$config\['smtp_user'\] = '';/\$config\['smtp_user'\] = '%u';/" /etc/roundcube/config.inc.php
    sed -i "s/\$config\['smtp_pass'\] = '';/\$config\['smtp_pass'\] = '%p';/" /etc/roundcube/config.inc.php
    
    # Configure Nginx for webmail
    cat > /etc/nginx/sites-available/webmail << EOF
server {
    listen 80;
    listen [::]:80;
    
    server_name webmail.*;
    
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    
    server_name webmail.*;
    
    ssl_certificate ${SSL_DIR}/\$host/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/\$host/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    
    root /var/lib/roundcube;
    index index.php;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php7.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    
    location ~ /\.(ht|svn|git) {
        deny all;
    }
}
EOF
    
    # Enable site
    ln -sf /etc/nginx/sites-available/webmail /etc/nginx/sites-enabled/
    
    # Restart services
    systemctl restart nginx
    systemctl restart php7.4-fpm
    
    # Save webmail credentials
    echo "Roundcube Database Credentials:" > /root/webmail_credentials.txt
    echo "Database: roundcube" >> /root/webmail_credentials.txt
    echo "Username: roundcube" >> /root/webmail_credentials.txt
    echo "Password: ${RC_DB_PASSWORD}" >> /root/webmail_credentials.txt
    chmod 600 /root/webmail_credentials.txt
    
    echo -e "${GREEN}Webmail setup completed.${NC}"
}

# Main execution
echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}=== Mail Server Setup with PostgreSQL =========${NC}"
echo -e "${GREEN}===============================================${NC}"

# Setup mail database
setup_mail_database

# Install and configure Postfix
install_postfix

# Install and configure Dovecot
install_dovecot

# Install email security
install_email_security

# Create test accounts
create_test_accounts

# Setup webmail
setup_webmail

echo -e "${GREEN}Mail server setup completed.${NC}"
echo -e "${YELLOW}Check the following files for credentials:${NC}"
echo " - /root/mail_db_credentials.txt - PostgreSQL mail user credentials"
echo " - /root/mail_accounts.txt - Mail account credentials"
echo " - /root/webmail_credentials.txt - Roundcube database