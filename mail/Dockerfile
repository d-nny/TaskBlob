FROM ubuntu:22.04

# Prevent interactive prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

# Install mail packages and dependencies
RUN apt-get update && apt-get install -y \
    postfix \
    postfix-pgsql \
    dovecot-core \
    dovecot-imapd \
    dovecot-pop3d \
    dovecot-pgsql \
    dovecot-lmtpd \
    dovecot-sieve \
    opendkim \
    opendkim-tools \
    spamassassin \
    clamav-daemon \
    clamav-freshclam \
    ssl-cert \
    ca-certificates \
    postgresql-client \
    supervisor \
    procps \
    net-tools \
    curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create required directories
RUN mkdir -p /var/mail /var/mail/vhosts /etc/mail

# Copy configuration files
COPY config/postfix /etc/postfix/
COPY config/dovecot /etc/dovecot/
COPY config/supervisor /etc/supervisor/conf.d/
COPY config/opendkim /etc/opendkim/
COPY scripts/entrypoint.sh /entrypoint.sh

# Set proper permissions
RUN chmod +x /entrypoint.sh && \
    groupadd -g 1000 vmail && \
    useradd -g vmail -u 1000 vmail -d /var/mail && \
    chown -R vmail:vmail /var/mail && \
    chown -R postfix:postfix /etc/postfix

# Expose mail ports
EXPOSE 25 465 587 110 995 143 993

# Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
