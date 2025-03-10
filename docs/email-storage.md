# Email Storage Architecture

TaskBlob implements a hybrid storage architecture for email, combining the reliability of filesystem storage with the management capabilities of a PostgreSQL database.

## Overview

The email system uses:
- **Postfix**: For SMTP service (sending/receiving)
- **Dovecot**: For IMAP/POP3 service (email access)
- **PostgreSQL**: For mail account management
- **OpenDKIM**: For email authentication

## Storage Architecture

### Mail Message Storage: Filesystem-Based

Actual email messages are stored on the filesystem rather than in the database for several reasons:

1. **Performance**: File-based storage is more efficient for large binary attachments
2. **Reliability**: Filesystem storage provides better durability for large mail stores
3. **Backup simplicity**: Mail directories can be backed up with standard tools
4. **Recovery**: Individual messages can be recovered without database expertise

Mail is stored in the `/var/mail` directory within the mail container, which is mapped to a Docker volume (`mail_data`) for persistence. This follows the [Maildir](https://en.wikipedia.org/wiki/Maildir) format, a reliable mail storage format that stores each message as a separate file.

```
/var/mail/
├── example.com/
│   ├── user1/
│   │   ├── cur/        # "Current" messages (read)
│   │   ├── new/        # New messages (unread)
│   │   └── tmp/        # Temporary messages during delivery
│   └── user2/
│       ├── cur/
│       ├── new/
│       └── tmp/
└── another-domain.com/
    └── ...
```

### Mail Account Management: PostgreSQL-Based

While the messages themselves are stored on the filesystem, mail accounts and routing information are managed in PostgreSQL:

- **Domains table**: Stores the valid mail domains
- **Mailboxes table**: Stores user accounts and their attributes
- **Aliases table**: Stores email forwarding rules
- **Forwards table**: Stores more complex forwarding configurations

Using a database for account management provides:
1. **High-performance lookups**: Quick authentication and mail routing
2. **Integration**: Easy connection with the admin panel
3. **Transactional safety**: Account changes are atomic
4. **Relationship management**: Between domains, users, and forwarding rules

## Configuration Flow

1. Admin creates domains and user accounts through the admin panel
2. Data is stored in PostgreSQL
3. Postfix and Dovecot query PostgreSQL to:
   - Validate incoming mail recipients
   - Authenticate users
   - Determine mail delivery locations
   - Process forwarding rules
4. Mail content is stored on disk in the Maildir format
5. Users access mail via IMAP/POP3 or webmail interface

## Backup Strategy

The hybrid approach allows for simple backup strategies:

1. **Database backup**: `pg_dump` for account information
2. **Mail backup**: File-based backup tools for mail content
3. **Config backup**: Docker volumes for configuration

## Disk Space Planning

When planning disk space, consider:

- **Database**: Typically small (~50MB even for hundreds of accounts)
- **Mail content**: Main storage requirement (plan 1-5GB per active user)
- **Logs**: Rotation policy impacts storage needs

## Storage Location Configuration

Storage locations can be configured in the `.env` file:

```
# Mail data directory
MAIL_DATA_DIR=/path/to/mail/storage

# Database connection info
POSTGRES_HOST=postgres
POSTGRES_DB=mail
```

By default, mail is stored in the Docker volume defined in `docker-compose.yml`.
