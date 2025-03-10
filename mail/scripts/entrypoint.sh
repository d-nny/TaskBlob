#!/bin/bash
set -e

# Wait for PostgreSQL to be ready
until PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB -c '\q'; do
  echo "PostgreSQL is unavailable - sleeping"
  sleep 5
done

echo "PostgreSQL is up - executing commands"

# Check if mail database exists, if not create it
if ! PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -lqt | cut -d \| -f 1 | grep -qw mail; then
  echo "Creating mail database and schema..."
  PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -c "CREATE DATABASE mail;"
  
  # Create mail tables
  PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d mail -c "
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
    
    CREATE INDEX idx_mailboxes_username ON mailboxes(username);
    CREATE INDEX idx_domains_domain ON domains(domain);
    CREATE INDEX idx_aliases_source ON aliases(source);
  "
  
  # Create database user
  PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -c "CREATE USER mail WITH ENCRYPTED PASSWORD 'mail';"
  PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -c "GRANT ALL PRIVILEGES ON DATABASE mail TO mail;"
  PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d mail -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO mail;"
  PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d mail -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO mail;"
  
  # Create postfix views
  PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d mail -c "
    CREATE VIEW postfix_virtual_domains AS
    SELECT domain FROM domains WHERE active = true;
    
    CREATE VIEW postfix_virtual_mailboxes AS
    SELECT username, maildir FROM mailboxes
    WHERE active = true;
    
    CREATE VIEW postfix_virtual_aliases AS
    SELECT source, destination FROM aliases
    WHERE active = true;
    
    GRANT SELECT ON postfix_virtual_domains TO mail;
    GRANT SELECT ON postfix_virtual_mailboxes TO mail;
    GRANT SELECT ON postfix_virtual_aliases TO mail;
  "
  
  # Create domain and admin user
  echo "Creating domain and admin user..."
  PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d mail -c "
    INSERT INTO domains (domain, description) VALUES ('${DOMAIN}', 'Primary domain');
  "
  
  DOMAIN_ID=$(PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d mail -t -c "SELECT id FROM domains WHERE domain = '${DOMAIN}';" | tr -d ' ')
  
  # Generate password hash for admin user
  ADMIN_PASS="changeme"
  ADMIN_PASS_HASH=$(doveadm pw -s SHA512-CRYPT -p "${ADMIN_PASS}")
  
  PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d mail -c "
    INSERT INTO mailboxes (
      username, domain_id, password, name, maildir, local_part
    ) VALUES (
      'admin@${DOMAIN}', ${DOMAIN_ID}, '${ADMIN_PASS_HASH}', 'Administrator', '/var/mail/vhosts/${DOMAIN}/admin', 'admin'
    );
    
    INSERT INTO aliases (
      source, destination, domain_id
    ) VALUES (
      'postmaster@${DOMAIN}', 'admin@${DOMAIN}', ${DOMAIN_ID}
    );
  "
  
  echo "Created mail database, domain and admin user."
  echo "Admin login: admin@${DOMAIN} / ${ADMIN_PASS}"
fi

# Configure Postfix with Dovecot integration
postconf -e "virtual_mailbox_domains = pgsql:/etc/postfix/pgsql/virtual_domains.cf"
postconf -e "virtual_mailbox_maps = pgsql:/etc/postfix/pgsql/virtual_mailbox_maps.cf"
postconf -e "virtual_alias_maps = pgsql:/etc/postfix/pgsql/virtual_alias_maps.cf"
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"

# Update SSL certificate paths
postconf -e "smtpd_tls_cert_file = /etc/ssl/mail/${DOMAIN}/fullchain.pem"
postconf -e "smtpd_tls_key_file = /etc/ssl/mail/${DOMAIN}/privkey.pem"
postconf -e "myhostname = ${MAIL_HOST}"

# Configure Dovecot for authentication
sed -i "s/^#auth_mechanisms.*/auth_mechanisms = plain login/" /etc/dovecot/conf.d/10-auth.conf
sed -i "s/^#disable_plaintext_auth.*/disable_plaintext_auth = no/" /etc/dovecot/conf.d/10-auth.conf
sed -i "s/^#ssl =.*/ssl = required/" /etc/dovecot/conf.d/10-ssl.conf

# Configure OpenDKIM if keys exist
if [ -f "/etc/dkim/${DOMAIN}/mail.private" ]; then
  echo "Configuring OpenDKIM..."
  sed -i "s/^Domain.*/Domain ${DOMAIN}/" /etc/opendkim.conf
  sed -i "s/^KeyFile.*/KeyFile \/etc\/dkim\/${DOMAIN}\/mail.private/" /etc/opendkim.conf
  sed -i "s/^Selector.*/Selector mail/" /etc/opendkim.conf
fi

# Create required directories for mail storage
mkdir -p /var/mail/vhosts/${DOMAIN}/admin
chown -R vmail:vmail /var/mail

# Start supervisord to manage all services
echo "Starting mail services..."
exec "$@"
