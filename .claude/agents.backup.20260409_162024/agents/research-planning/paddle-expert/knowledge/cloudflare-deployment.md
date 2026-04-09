# Paddle + Cloudflare Workers Deployment Guide

**Complete guide to deploying Paddle billing on Cloudflare Workers**

---

## Table of Contents

1. [Overview](#overview)
2. [Secrets Management Strategy](#secrets-management-strategy)
3. [Production Deployment Workflow](#production-deployment-workflow)
4. [Local Development Setup](#local-development-setup)
5. [Team Access Control](#team-access-control)
6. [Common Deployment Scenarios](#common-deployment-scenarios)
7. [Troubleshooting](#troubleshooting)

---

## Overview

Paddle integrations deployed on Cloudflare Workers require careful secrets
management to ensure security while maintaining development convenience.

**Key Insight**: Production and local development are fundamentally different
environments with different secrets mechanisms!

---

## Secrets Management Strategy

### The Core Distinction

| Aspect                 | Production (Cloudflare Workers)            | Local Dev (npm run dev)         |
| ---------------------- | ------------------------------------------ | ------------------------------- |
| **Runtime**            | Cloudflare Workers (V8 isolates)           | Node.js (Next.js dev server)    |
| **Secrets Storage**    | Cloudflare secrets (`wrangler secret put`) | `.env.local` file (gitignored)  |
| **Access Pattern**     | `env.PADDLE_API_KEY`                       | `process.env.PADDLE_API_KEY`    |
| **.env.local Needed?** | ❌ NO                                      | ✅ YES                          |
| **Secrets Source**     | Cloudflare dashboard                       | Copy from Cloudflare or service |

### Universal Code Pattern

**Always write code that works in BOTH environments:**

```typescript
import { NextRequest } from 'next/server';
import { getCloudflareContext } from '@opennextjs/cloudflare';

export async function POST(request: NextRequest) {
  // Get Cloudflare context (undefined in local dev)
  const { env } = await getCloudflareContext({ async: true });

  // ✅ Fallback pattern: production first, local second
  const paddleApiKey = env?.PADDLE_API_KEY || process.env.PADDLE_API_KEY;
  const webhookSecret =
    env?.PADDLE_WEBHOOK_SECRET || process.env.PADDLE_WEBHOOK_SECRET;

  // Now works in both production and local dev!
  if (!paddleApiKey || !webhookSecret) {
    return new Response('Configuration error', { status: 500 });
  }

  // Use secrets normally...
}
```

**How it works:**

- **Production (Cloudflare)**:
  - `env.PADDLE_API_KEY` exists (Cloudflare secret)
  - Uses Cloudflare secret directly
  - Never touches `process.env`

- **Local Dev (Node.js)**:
  - `env` is undefined (no Cloudflare binding)
  - Falls back to `process.env.PADDLE_API_KEY`
  - Reads from `.env.local`

---

## Production Deployment Workflow

### Step 1: Set Cloudflare Secrets (One-Time)

```bash
cd /path/to/your-project

# Set Paddle API key
wrangler secret put PADDLE_API_KEY
# Prompt: Enter value for PADDLE_API_KEY
# Paste: pdl_live_abc123xyz789... (from Paddle dashboard)

# Set webhook secret (CRITICAL for security!)
wrangler secret put PADDLE_WEBHOOK_SECRET
# Prompt: Enter value for PADDLE_WEBHOOK_SECRET
# Paste: pdl_ntfset_xyz789abc123... (from Paddle webhook settings)

# Verify secrets are set
wrangler secret list
# Output:
# PADDLE_API_KEY
# PADDLE_WEBHOOK_SECRET
```

**Important**:

- Secrets are **encrypted** by Cloudflare
- Secrets are **NOT visible** in dashboard or `wrangler.toml`
- Secrets are **environment-specific** (set separately for staging/production)
- To update a secret: run `wrangler secret put` again

### Step 2: Configure Public Variables (wrangler.toml)

```toml
# wrangler.toml
name = "your-app"
compatibility_date = "2023-12-01"

# Public variables (safe to commit to git)
[vars]
ENVIRONMENT = "production"
NEXT_PUBLIC_SITE_URL = "https://yourdomain.com"

# Paddle public configuration
NEXT_PUBLIC_PADDLE_VENDOR_ID = "232110"
NEXT_PUBLIC_PADDLE_ENVIRONMENT = "production"
NEXT_PUBLIC_PADDLE_CLIENT_TOKEN = "live_78f1193c72d118ad70ed5b2c2f2"
PADDLE_WEBHOOK_ID = "ntfset_01jxts5prxmd9y82gh5frmkhhf"
PADDLE_ENVIRONMENT = "production"

# Feature flags
NEXT_PUBLIC_ENABLE_CHECKOUT = "true"
NEXT_PUBLIC_ENABLE_SIGNUP = "true"

# Database binding
[[d1_databases]]
binding = "HIVE_DB"
database_name = "hive-user-db"
database_id = "your-d1-database-id"
```

**What goes in wrangler.toml:**

- ✅ Public variables (`NEXT_PUBLIC_*`)
- ✅ Non-sensitive IDs (vendor ID, webhook ID)
- ✅ Environment flags
- ❌ **NEVER** API keys or secrets

### Step 3: Deploy to Cloudflare

```bash
# Build Next.js for Cloudflare Workers
npm run build

# Deploy to production
wrangler deploy

# Output:
# ✨ Built successfully
# 🌍 Uploading... (100%)
# ✨ Deployment complete!
# 🌐 https://your-app.workers.dev
```

### Step 4: Verify Deployment

```bash
# Test webhook endpoint (should return 401 without valid signature)
curl -X POST https://yourdomain.com/api/paddle/webhook \
  -H "Content-Type: application/json" \
  -d '{"test":"data"}'

# Expected: 401 Unauthorized (signature verification working!)

# Test health endpoint
curl https://yourdomain.com/api/health

# Expected: 200 OK
```

### Step 5: Update Paddle Webhook URL

1. Go to Paddle Dashboard → Developer Tools → Notifications
2. Click on your webhook
3. Update "Destination URL" to: `https://yourdomain.com/api/paddle/webhook`
4. Click "Save"
5. Click "Send Test Event" to verify
6. Check Cloudflare logs: `wrangler tail`

**Verification checklist:**

- [ ] Cloudflare secrets set correctly
- [ ] `wrangler.toml` has public variables
- [ ] Deployment succeeded
- [ ] Webhook endpoint returns 401 (signature verification working)
- [ ] Paddle webhook URL updated to production domain
- [ ] Test webhook fires successfully (200 OK)

---

## Local Development Setup

### Step 1: Create .env.local

```bash
cd /path/to/your-project

# Create .env.local (make sure it's gitignored!)
touch .env.local

# Verify it's gitignored
git status | grep .env.local  # Should return nothing
```

### Step 2: Populate .env.local

**Option A: Retrieve from Cloudflare (recommended)**

```bash
# Get each secret from production Cloudflare
wrangler secret get PADDLE_API_KEY
# Copy output: pdl_live_abc123xyz789...

wrangler secret get PADDLE_WEBHOOK_SECRET
# Copy output: pdl_ntfset_xyz789abc123...

# Add to .env.local:
# PADDLE_API_KEY=pdl_live_abc123xyz789...
# PADDLE_WEBHOOK_SECRET=pdl_ntfset_xyz789abc123...
```

**Option B: Copy from Paddle Dashboard**

1. **Paddle Dashboard → Developer Tools → Authentication**
2. Copy "API Key"
3. **Paddle Dashboard → Developer Tools → Notifications**
4. Click your webhook → "Show Secret Key"
5. Copy webhook secret

**Option C: Use Sandbox Credentials (safer for local dev)**

```bash
# Use sandbox API key and webhook secret instead of production
# This prevents accidentally affecting production data
PADDLE_API_KEY=pdl_sdbx_apikey_sandbox123...
PADDLE_WEBHOOK_SECRET=pdl_ntfset_sandbox789...
PADDLE_ENVIRONMENT=sandbox
NEXT_PUBLIC_PADDLE_ENVIRONMENT=sandbox
NEXT_PUBLIC_PADDLE_CLIENT_TOKEN=test_sandbox_token...
```

### Step 3: Complete .env.local

```bash
# .env.local (complete example)

# API Credentials
PADDLE_VENDOR_ID=232110
PADDLE_API_KEY=pdl_sdbx_apikey_abc123...  # Sandbox for local dev
PADDLE_ENVIRONMENT=sandbox

# Webhook Configuration
PADDLE_WEBHOOK_ID=ntfset_01jxvaqejk038xjx7gn7qc8br7
PADDLE_WEBHOOK_SECRET=pdl_ntfset_xyz789...

# Client-Side Configuration
NEXT_PUBLIC_PADDLE_VENDOR_ID=232110
NEXT_PUBLIC_PADDLE_ENVIRONMENT=sandbox
NEXT_PUBLIC_PADDLE_CLIENT_TOKEN=test_78f1193c72d118ad70ed5b2c2f2

# Product Price IDs (sandbox IDs for local dev)
PADDLE_PRICE_BASIC=pri_01sandbox_basic_abc123
PADDLE_PRICE_STANDARD=pri_01sandbox_standard_def456
PADDLE_PRICE_PREMIUM=pri_01sandbox_premium_ghi789
PADDLE_PRICE_UNLIMITED=pri_01sandbox_unlimited_jkl012
PADDLE_PRICE_TEAM=pri_01sandbox_team_mno345
PADDLE_PRICE_CREDITS_25=pri_01sandbox_credits25_pqr678
PADDLE_PRICE_CREDITS_75=pri_01sandbox_credits75_stu901
PADDLE_PRICE_CREDITS_200=pri_01sandbox_credits200_vwx234

# Feature Flags
NEXT_PUBLIC_ENABLE_CHECKOUT=true
NEXT_PUBLIC_ENABLE_SIGNUP=true

# Other services (SMTP, JWT, etc.)
SMTP2GO_API_KEY=api-your_smtp_key_here
JWT_SECRET=your_jwt_secret_here
```

### Step 4: Secure .env.local

```bash
# Set restrictive permissions
chmod 600 .env.local

# Verify permissions
ls -la .env.local
# Should show: -rw------- (owner read/write only)

# Verify not tracked by git
git status | grep .env.local  # Should return nothing
```

### Step 5: Test Local Development

```bash
# Start development server
npm run dev

# Test Paddle integration
# Open browser to: http://localhost:3001

# Check browser console:
# - Paddle.js should load successfully
# - Environment should be "sandbox"

# Test webhook locally (should fail with 401)
curl -X POST http://localhost:3001/api/paddle/webhook \
  -H "Content-Type: application/json" \
  -d '{"test":"data"}'

# Expected: 401 Unauthorized (signature verification working!)
```

---

## Team Access Control

### For Team Leads: Grant Access

**Cloudflare Dashboard:**

1. Go to: Account Home → Manage Account → Members
2. Click "Invite Member"
3. Enter team member email
4. Select role:
   - **Administrator**: Full access (read/write secrets)
   - **Developer**: Deploy access (no secret visibility)
   - **Viewer**: Read-only (no secret access)
5. Send invitation

**Paddle Dashboard:**

1. Go to: Settings → Team Members
2. Click "Invite Team Member"
3. Enter email and select role
4. Send invitation

### For New Team Members: Get Access

**Step 1: Accept Invitations**

- Check email for Cloudflare and Paddle invitations
- Accept both invitations
- Set up accounts

**Step 2: Install Wrangler**

```bash
npm install -g wrangler

# Authenticate
wrangler login
# Opens browser for authentication
```

**Step 3: Retrieve Secrets for Local Dev**

```bash
# Clone repository
git clone https://github.com/your-org/your-project.git
cd your-project

# Install dependencies
npm install

# Create .env.local
touch .env.local

# Retrieve secrets from Cloudflare
wrangler secret get PADDLE_API_KEY
# Copy output to .env.local

wrangler secret get PADDLE_WEBHOOK_SECRET
# Copy output to .env.local

# Or ask team lead for secrets via secure channel
# (1Password, encrypted file, etc.)

# Secure the file
chmod 600 .env.local

# Verify not tracked
git status | grep .env.local  # Should return nothing
```

**Step 4: Test Local Development**

```bash
npm run dev

# Verify Paddle integration works
# Test with sandbox credentials
```

---

## Common Deployment Scenarios

### Scenario 1: Initial Production Deployment

```bash
# 1. Set production secrets
wrangler secret put PADDLE_API_KEY  # Production key
wrangler secret put PADDLE_WEBHOOK_SECRET  # Production webhook secret

# 2. Update wrangler.toml
# Set NEXT_PUBLIC_PADDLE_ENVIRONMENT = "production"
# Set NEXT_PUBLIC_PADDLE_CLIENT_TOKEN = "live_..."

# 3. Build and deploy
npm run build
wrangler deploy

# 4. Update Paddle webhook URL
# Paddle Dashboard → Notifications → Update to production URL

# 5. Test with real checkout
# Use real credit card (sandbox cards won't work in production!)
```

### Scenario 2: Updating Secrets (Key Rotation)

```bash
# 1. Generate new API key in Paddle Dashboard
# Developer Tools → Authentication → Create New Key

# 2. Update Cloudflare secret
wrangler secret put PADDLE_API_KEY
# Enter new API key value

# 3. No redeployment needed!
# Secrets take effect immediately

# 4. Verify new key works
curl https://yourdomain.com/api/health

# 5. Revoke old key in Paddle Dashboard
```

### Scenario 3: Staging Environment

```bash
# 1. Set staging-specific secrets
wrangler secret put PADDLE_API_KEY --env staging
# Enter sandbox API key for staging

wrangler secret put PADDLE_WEBHOOK_SECRET --env staging
# Enter sandbox webhook secret

# 2. Configure wrangler.toml for staging
# Add [env.staging] section
[env.staging]
name = "your-app-staging"
vars = { NEXT_PUBLIC_PADDLE_ENVIRONMENT = "sandbox" }

# 3. Deploy to staging
wrangler deploy --env staging

# 4. Test on staging
curl https://your-app-staging.workers.dev/api/health
```

### Scenario 4: Emergency Rollback

```bash
# If deployment has critical issues:

# Option 1: Rollback to previous deployment
wrangler rollback

# Option 2: Disable checkout temporarily
# Update wrangler.toml:
NEXT_PUBLIC_ENABLE_CHECKOUT = "false"
wrangler deploy

# Option 3: Revert git commit and redeploy
git revert HEAD
npm run build
wrangler deploy
```

---

## Troubleshooting

### Issue 1: "PADDLE_API_KEY is undefined" in Production

**Symptom**: API calls fail with authentication errors

**Cause**: Secret not set in Cloudflare

**Solution**:

```bash
# Check if secret exists
wrangler secret list | grep PADDLE_API_KEY

# If missing, set it
wrangler secret put PADDLE_API_KEY

# Verify (no redeploy needed!)
curl https://yourdomain.com/api/health
```

### Issue 2: ".env.local Not Working" Locally

**Symptom**: Local dev can't access secrets

**Cause**: Code not using fallback pattern, or `.env.local` not loaded

**Solution**:

```typescript
// ❌ BAD: Production-only
const apiKey = env.PADDLE_API_KEY; // undefined locally!

// ✅ GOOD: Fallback pattern
const apiKey = env?.PADDLE_API_KEY || process.env.PADDLE_API_KEY;
```

**Verify `.env.local` is loaded**:

```bash
# In your code:
console.log('PADDLE_API_KEY:', process.env.PADDLE_API_KEY ? 'SET' : 'MISSING')

# Run dev server
npm run dev

# Should log: PADDLE_API_KEY: SET
```

### Issue 3: "Wrong Environment" (Sandbox in Production)

**Symptom**: Production using sandbox credentials

**Cause**: Wrong environment variables in `wrangler.toml`

**Solution**:

```bash
# Check wrangler.toml
grep PADDLE wrangler.toml

# Should show for production:
# NEXT_PUBLIC_PADDLE_ENVIRONMENT = "production"
# NEXT_PUBLIC_PADDLE_CLIENT_TOKEN = "live_..." (NOT "test_")

# Update if wrong
# Redeploy
wrangler deploy
```

### Issue 4: ".env.local Committed to Git" (CRITICAL!)

**Symptom**: `.env.local` appears in `git status`

**Cause**: Not in `.gitignore`

**Solution**:

```bash
# Add to .gitignore
echo ".env.local" >> .gitignore

# Remove from git cache
git rm --cached .env.local

# Verify
git status | grep .env.local  # Should return nothing

# IMPORTANT: Rotate ALL secrets immediately!
# Secrets that were committed are now compromised
```

### Issue 5: "Team Member Can't Access Secrets"

**Symptom**: New team member gets authentication errors with Wrangler

**Cause**: Not added to Cloudflare account

**Solution**:

1. Team lead: Invite member via Cloudflare dashboard
2. Team member: Accept invitation
3. Team member: Run `wrangler login` again
4. Team member: Retry `wrangler secret get`

---

## Security Best Practices

### Secrets Hygiene

1. **Never commit secrets to git**

   ```bash
   # Always verify before commit
   git status | grep -E ".env|secret"
   # Should return nothing
   ```

2. **Use separate secrets for each environment**

   ```bash
   # Sandbox (for local dev and staging)
   wrangler secret put PADDLE_API_KEY --env staging
   # Production (for live site)
   wrangler secret put PADDLE_API_KEY --env production
   ```

3. **Rotate secrets regularly**
   - Quarterly: Paddle API keys
   - Immediately: If compromised

4. **Limit access**
   - Admins: Full secret access
   - Developers: Deploy only (no secret visibility)
   - CI/CD: Minimal required secrets

### Code Security

1. **Always use fallback pattern**

   ```typescript
   const secret = env?.SECRET || process.env.SECRET;
   ```

2. **Never log secrets**

   ```typescript
   // ❌ BAD
   console.log('API Key:', env.PADDLE_API_KEY);

   // ✅ GOOD
   console.log('API Key:', env.PADDLE_API_KEY ? 'SET' : 'MISSING');
   ```

3. **Never expose secrets to frontend**

   ```typescript
   // ❌ BAD
   return Response.json({ apiKey: env.PADDLE_API_KEY });

   // ✅ GOOD
   // Keep secrets server-side only
   ```

---

## Quick Reference Commands

### Production Deployment

```bash
# Set secrets
wrangler secret put PADDLE_API_KEY
wrangler secret put PADDLE_WEBHOOK_SECRET

# Deploy
npm run build
wrangler deploy

# Verify
wrangler secret list
curl https://yourdomain.com/api/health
```

### Local Development

```bash
# Create .env.local
touch .env.local

# Get secrets
wrangler secret get PADDLE_API_KEY  # Copy to .env.local
wrangler secret get PADDLE_WEBHOOK_SECRET  # Copy to .env.local

# Run
npm run dev
```

### Troubleshooting

```bash
# Check secrets
wrangler secret list

# View logs
wrangler tail

# Test webhook
curl -X POST https://yourdomain.com/api/paddle/webhook -d '{"test":"data"}'
```

---

**Last Updated**: 2025-10-09 **Version**: 1.0.0 **Maintained By**: paddle-expert
agent

**Related Documentation**:

- [Configuration Guide](./configuration-guide.md)
- [Cloudflare Secrets Architecture](../../../docs/CLOUDFLARE_SECRETS_ARCHITECTURE.md)
- [Quick Reference](./quick-reference.md)
