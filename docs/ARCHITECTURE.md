# Architecture — IT-Stack IREDMAIL

## Overview

iRedMail provides a complete email stack (Postfix, Dovecot, SpamAssassin, ClamAV) for the organization's email infrastructure.

## Role in IT-Stack

- **Category:** communications
- **Phase:** 2
- **Server:** lab-comm1 (10.0.50.14)
- **Ports:** 25 (SMTP), 143 (IMAP), 993 (IMAPS), 587 (Submission)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → iredmail → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog
