# Security Considerations

This document outlines security considerations when using this codebase, particularly when sharing it in a public repository.

## Potential Risks

When deploying server infrastructure code from a public repository, consider the following security aspects:

### 1. Environment Variables and Secrets

- **Never commit the actual `.env` file** (it's already in .gitignore)
- All secrets, API keys, and credentials should only exist in your local `.env` file
- The template file does not contain real credentials, but you should still review it

### 2. Default Passwords

The codebase contains references to default passwords (like "changeme!") that should be changed immediately:

- In `setup-dns.sh`: Change the default admin user password
- In `master-setup.sh`: Change the SSL configuration 
- In the admin panel: Update credentials after first login

### 3. IP Address Exposure

- The code allows configuring IP addresses via environment variables
- Never commit your actual server IP addresses to public repositories
- Consider using a variable like `$SERVER_IP` instead of revealing actual addresses in documentation

### 4. SSL Certificate Management

- The codebase includes SSL certificate management
- Ensure certificates and private keys are not committed
- The `/ssl` directory should be in your `.gitignore`

### 5. Admin Panel Security

- The admin panel requires proper HTTPS configuration 
- Always use a strong password for the admin user
- Consider implementing IP restrictions for the admin panel
- Consider adding two-factor authentication to enhance security

## Recommendations Before Going Public

1. **Audit for secrets**: Perform a complete audit to ensure no secrets, API keys, passwords or sensitive information remains in the code
   ```bash
   git grep -l "API_KEY\|PASSWORD\|SECRET\|CREDENTIALS"
   ```

2. **Add to .gitignore**:
   ```
   .env
   *.pem
   *.key
   *.crt
   /ssl/
   /dkim/
   ```

3. **Secure default configurations**:
   - Remove any default passwords
   - Use placeholders like `YOUR_SECURE_PASSWORD_HERE` in templates
   - Add warnings about changing default settings

4. **Implement rate limiting**:
   - Add proper rate limiting to the admin panel
   - Implement fail2ban for SSH and admin panel login attempts

5. **Regular security updates**:
   - Document the need for regular security updates
   - Consider adding a security update script

## Security Hardening After Deployment

After deploying your server:

1. **Change default passwords immediately**
2. **Run a security audit**:
   ```bash
   # Install security audit tools
   apt-get install lynis
   # Run a system audit
   lynis audit system
   ```
3. **Enable firewall with restrictive rules**
4. **Set up regular security updates**
5. **Configure proper log monitoring**
6. **Implement intrusion detection**

## Reporting Security Issues

If you discover a security vulnerability, please report it to [your contact email] rather than opening a public issue.
