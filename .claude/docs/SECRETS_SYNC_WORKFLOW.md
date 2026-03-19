# Secrets Sync Workflow

## Overview

This document describes the complete workflow for managing and syncing environment secrets across HiveTechs projects using the centralized secrets vault in claude-pattern.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    claude-pattern Repository                 │
│                  (Template & Secrets Vault)                  │
│                                                              │
│  .claude/secrets/                                            │
│  ├── .env.base              (non-sensitive config)          │
│  ├── .env.paddle.sandbox    (sandbox keys - POPULATED)      │
│  ├── .env.paddle.production (production keys - TEMPLATE)    │
│  ├── .env.smtp              (email keys - TEMPLATE)         │
│  └── .env.jwt               (auth secrets - TEMPLATE)       │
│                                                              │
│  .claude/scripts/                                            │
│  ├── sync-secrets.sh        (sync to projects)              │
│  └── backup-secrets.sh      (create backups)                │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ Manual Sync
                              ├─────────────────┬─────────────────┐
                              ▼                 ▼                 ▼
┌─────────────────┐  ┌──────────────────┐  ┌─────────────────┐
│ hivetechs-      │  │      hive        │  │ new-project     │
│   website       │  │                  │  │                 │
│                 │  │                  │  │                 │
│ .env.local ✓    │  │ .env.local ✓     │  │ .env.local ✓    │
└─────────────────┘  └──────────────────┘  └─────────────────┘
```

## Security Model

### Multi-Layer Protection

1. **Git Ignore (Layer 1)**:
   - Root `.gitignore`: `**/secrets/`
   - Secrets `.gitignore`: Deny all except docs
   - Double protection against accidental commits

2. **File Permissions (Layer 2)**:
   - Directory: `700` (owner only)
   - Secret files: `600` (owner read/write only)
   - Scripts verify permissions before operations

3. **Sync Validation (Layer 3)**:
   - Verifies target `.gitignore` before sync
   - Checks git status after sync
   - Prevents syncing if secrets would be tracked

4. **Audit Trail (Layer 4)**:
   - All syncs logged to `last-sync.log`
   - Timestamp and target recorded
   - Success/failure status tracked

## Workflows

### 1. Initial Setup (One-Time)

**Already completed** as part of this implementation:

- ✅ Created `.claude/secrets/` directory
- ✅ Populated `.env.paddle.sandbox` with actual keys
- ✅ Created templates for production secrets
- ✅ Set secure file permissions
- ✅ Verified git-ignore working
- ✅ Created sync and backup scripts

### 2. Populating Missing Secrets (User Action Required)

**Status**: Templates created, need actual values

**Option A: Retrieve from Cloudflare Workers**
```bash
cd ~/Developer/Private/hivetechs-website

# Get secrets (requires Cloudflare authentication)
wrangler secret get SMTP2GO_API_KEY
wrangler secret get RESEND_API_KEY
wrangler secret get JWT_SECRET
wrangler secret get JWT_SERVICE_SECRET
wrangler secret get CRON_SECRET_TOKEN
wrangler secret get PADDLE_WEBHOOK_SECRET
```

Copy values into respective `.env.*` files in `.claude/secrets/`.

**Option B: Retrieve from Service Dashboards**
- SMTP2GO: https://app.smtp2go.com/settings/apikeys/
- Resend: https://resend.com/api-keys
- Paddle: https://vendors.paddle.com/ → Developer Tools

**Option C: Generate New Secrets (JWT only)**
```bash
# For JWT and cron secrets
node -e "console.log(require('crypto').randomBytes(64).toString('base64url'))"
```

See: `.claude/secrets/SECRETS_MANAGEMENT_GUIDE.md` for detailed instructions.

### 3. Syncing to Existing Projects

**Development (Sandbox)**:
```bash
cd ~/Developer/Private/claude-pattern

# Sync sandbox config to hivetechs-website
.claude/scripts/sync-secrets.sh --sandbox ~/Developer/Private/hivetechs-website

# Sync sandbox config to hive
.claude/scripts/sync-secrets.sh --sandbox ~/Developer/Private/hive
```

**Production**:
```bash
# After populating production secrets
.claude/scripts/sync-secrets.sh --production ~/Developer/Private/hivetechs-website
```

**All Projects**:
```bash
# Sync to all known projects (defined in script)
.claude/scripts/sync-secrets.sh --all
```

### 4. Syncing to New Projects

When creating a new project from claude-pattern template:

```bash
# 1. Create new project from template
git clone ~/Developer/Private/claude-pattern ~/Developer/Private/new-project

# 2. Sync secrets (choose environment)
cd ~/Developer/Private/claude-pattern
.claude/scripts/sync-secrets.sh --sandbox ~/Developer/Private/new-project

# 3. Verify .env.local created and git-ignored
cd ~/Developer/Private/new-project
ls -la .env.local  # Should exist with 600 permissions
git status | grep .env.local  # Should return nothing
```

### 5. Creating Backups

**Manual Backup**:
```bash
cd ~/Developer/Private/claude-pattern
.claude/scripts/backup-secrets.sh
```

Creates timestamped backup in `~/Backups/`:
- Compressed tar.gz
- 600 permissions
- Keeps last 10 backups (auto-cleanup)

**Recommended Schedule**:
- Weekly backups before major changes
- After updating any secrets
- Before rotating credentials

**Backup Storage**:
- Local: `~/Backups/claude-secrets-YYYYMMDD-HHMMSS.tar.gz`
- Encrypted: Store on encrypted volume/USB (recommended)
- DO NOT store in cloud services without encryption

### 6. Rotating Secrets

**When to Rotate**:
- Quarterly (Paddle, JWT secrets)
- Annually (SMTP keys)
- Immediately if compromised
- Before employee offboarding

**Rotation Process**:
```bash
# 1. Generate new secrets (example for JWT)
NEW_SECRET=$(node -e "console.log(require('crypto').randomBytes(64).toString('base64url'))")

# 2. Update vault file
echo "JWT_SECRET=$NEW_SECRET" > .claude/secrets/.env.jwt.new
mv .claude/secrets/.env.jwt.new .claude/secrets/.env.jwt
chmod 600 .claude/secrets/.env.jwt

# 3. Update Cloudflare Workers
cd ~/Developer/Private/hivetechs-website
wrangler secret put JWT_SECRET
# Paste new secret when prompted

# 4. Sync to all active projects
cd ~/Developer/Private/claude-pattern
.claude/scripts/sync-secrets.sh --all

# 5. Update inventory
# Edit .claude/secrets/secrets-inventory.md with rotation date

# 6. Create backup
.claude/scripts/backup-secrets.sh
```

### 7. Emergency Recovery

**If secrets appear in git status**:
```bash
# 1. STOP - do not commit
git status | grep secrets

# 2. Remove from staging
git reset HEAD .claude/secrets/

# 3. Verify .gitignore
git check-ignore .claude/secrets/.env.paddle.sandbox

# 4. If cached, remove cache
git rm -r --cached .claude/secrets
```

**If secrets were committed**:
```bash
# 1. IMMEDIATELY rotate all exposed secrets
# See service dashboards (Paddle, SMTP2GO, Resend)

# 2. Remove from git history
git filter-branch --force --index-filter \
  "git rm --cached --ignore-unmatch .claude/secrets/.env.*" \
  --prune-empty --tag-name-filter cat -- --all

# 3. Force push (if already pushed to remote)
git push origin --force --all

# 4. Verify removal
git log --all --full-history -- .claude/secrets/
```

**If secrets are compromised**:
1. Rotate immediately in service dashboards
2. Update vault files
3. Sync to all projects
4. Monitor service usage for suspicious activity
5. Update inventory with incident notes

## Integration with Existing Sync Job

### Current Sync Manifest

The existing repository sync job (if automated) syncs:
- Documentation files (*.md)
- Agent knowledge base
- Public templates (.env.paddle.example)

### Secrets Sync (Manual Only)

**CRITICAL**: Secrets sync is NEVER automated. Always requires explicit user action.

**Why Manual?**
- User awareness required for security
- Audit trail needed
- Prevents accidental exposure
- Allows review before copying sensitive data

## Verification Checklist

Before any git operation:
- [ ] Run `git status | grep secrets` (should return nothing)
- [ ] Verify file permissions: `ls -la .claude/secrets/.env.*` (should be 600)
- [ ] Check inventory is current: `cat .claude/secrets/secrets-inventory.md`
- [ ] Confirm recent backup exists: `ls -lt ~/Backups/claude-secrets-*`

Before syncing to project:
- [ ] Target project has `.env.local` in `.gitignore`
- [ ] Vault secrets are current
- [ ] Correct environment selected (sandbox vs production)
- [ ] Sync script has execute permissions

After syncing to project:
- [ ] `.env.local` exists in target
- [ ] File has 600 permissions
- [ ] `git status` in target shows no .env.local
- [ ] Application starts successfully with new config

## Troubleshooting

### Sync script fails with "not found"
```bash
# Verify script exists and is executable
ls -la .claude/scripts/sync-secrets.sh
chmod +x .claude/scripts/sync-secrets.sh
```

### Secrets appear in git status after sync
```bash
# In target project
echo ".env.local" >> .gitignore
git rm --cached .env.local
git status  # Should no longer show .env.local
```

### File permissions reset after sync
```bash
# Scripts automatically set 600, but verify
chmod 600 .env.local
```

### Wrong environment synced
```bash
# Re-sync with correct environment
cd ~/Developer/Private/claude-pattern
.claude/scripts/sync-secrets.sh --sandbox /path/to/project  # or --production
```

## Maintenance Tasks

### Daily
- No daily tasks (secrets are stable)

### Weekly
- [ ] Create backup if secrets changed
- [ ] Verify `.gitignore` still effective

### Monthly
- [ ] Review sync logs: `cat .claude/secrets/last-sync.log`
- [ ] Audit secret usage
- [ ] Check Cloudflare Workers secrets match vault

### Quarterly
- [ ] Rotate Paddle API keys
- [ ] Rotate JWT secrets
- [ ] Update inventory with rotation dates
- [ ] Verify backups are recoverable

### Annually
- [ ] Rotate SMTP API keys
- [ ] Security audit of entire secrets management system
- [ ] Review and update this documentation

## Script Reference

### sync-secrets.sh

**Purpose**: Copy secrets from vault to target projects

**Usage**:
```bash
# Sync sandbox to specific project
.claude/scripts/sync-secrets.sh --sandbox /path/to/project

# Sync production to specific project
.claude/scripts/sync-secrets.sh --production /path/to/project

# Sync to all known projects
.claude/scripts/sync-secrets.sh --all

# Help
.claude/scripts/sync-secrets.sh --help
```

**Features**:
- Combines base config + environment-specific secrets
- Verifies .gitignore before copying
- Sets 600 permissions automatically
- Logs all operations
- Validates git status after sync

### backup-secrets.sh

**Purpose**: Create timestamped encrypted backups

**Usage**:
```bash
# Create backup
.claude/scripts/backup-secrets.sh

# Custom backup location
BACKUP_DIR=/path/to/encrypted/volume .claude/scripts/backup-secrets.sh
```

**Features**:
- Timestamped filenames
- Compressed tar.gz
- 600 permissions
- Integrity verification
- Auto-cleanup (keeps last 10)

## Security Best Practices

1. **Never commit secrets to git** - Multiple protection layers prevent this
2. **Rotate regularly** - Quarterly for critical secrets, annually for others
3. **Use different secrets per environment** - Never reuse dev secrets in production
4. **Monitor access** - Review sync logs monthly
5. **Backup regularly** - Weekly if actively changing, monthly otherwise
6. **Encrypt backups** - Store on encrypted volumes only
7. **Limit access** - File permissions restrict to owner only
8. **Audit trail** - All operations logged
9. **Verify constantly** - Check git status before every commit
10. **Plan for compromise** - Know how to rotate quickly

## Support Contacts

- **Paddle**: support@paddle.com
- **SMTP2GO**: support@smtp2go.com
- **Resend**: support@resend.com
- **Cloudflare**: support@cloudflare.com
- **Internal**: founder@hivetechs.io

---

**Version**: 1.0
**Last Updated**: 2025-10-09
**Maintained By**: Verone Lazio
**Security Review**: Annual (Next: 2026-10-09)
