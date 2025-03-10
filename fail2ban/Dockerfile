FROM alpine:latest

# Install fail2ban and required packages
RUN apk --no-cache add \
    fail2ban \
    python3 \
    py3-pip \
    tzdata \
    bash \
    iptables \
    ip6tables

# Set up working directory
WORKDIR /etc/fail2ban

# Copy configuration files
COPY config/jail.local /etc/fail2ban/jail.local
COPY config/filter.d/ /etc/fail2ban/filter.d/

# Create required directories
RUN mkdir -p /var/run/fail2ban

# Expose fail2ban socket directory for other containers
VOLUME ["/var/run/fail2ban"]

# Since fail2ban needs to interact with host firewall
# We need to run the container with network=host and privileged=true

# Start fail2ban (configurable between foreground/daemon mode)
CMD ["fail2ban-client", "-f", "start"]
