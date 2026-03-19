# Cloudflare Workers Secrets Architecture

**Version**: 1.0
**Last Updated**: 2025-10-09
**Applies To**: Next.js + Cloudflare Workers deployments

---

## Overview

This guide explains how secrets management works in Cloudflare Workers-based Next.js applications, contrasting production deployment with local development.

## Table of Contents

1. [Quick Decision Guide](#quick-decision-guide)
2. [Production Secrets (Cloudflare Workers)](#production-secrets-cloudflare-workers)
3. [Local Development Secrets (.env.local)](#local-development-secrets-envlocal)
4. [Code Patterns for Universal Compatibility](#code-patterns-for-universal-compatibility)
5. [Team Onboarding Workflow](#team-onboarding-workflow)
6. [Common Pitfalls and Solutions](#common-pitfalls-and-solutions)
7. [Security Best Practices](#security-best-practices)

---

## Quick Decision Guide

**Do I need .env.local files?**

```
┌─────────────────────────────────────────┐
│ What are you trying to do?             │
└─────────────────┬───────────────────────┘
                  │
        ┌─────────┴─────────┐
        │                   │
        ▼                   ▼
┌──────────────┐    ┌──────────────┐
│ Deploy to    │    │ Run locally  │
│ Production   │    │ (npm run dev)│
└──────┬───────┘    └──────┬───────┘
       │                   │
       ▼                   ▼
┌──────────────┐    ┌──────────────┐
│ Use wrangler │    │ Create       │
│ secret put   │    │ .env.local   │
│              │    │              │
│ NO .env file │    │ YES need     │
│ needed!      │    │ secrets file │
└──────────────┘    └──────────────┘
```

**Quick Answer:**

| Environment | Need .env.local? | How to manage secrets |
|-------------|-----------------|----------------------|
| **Production (hivetechs.io)** | ❌ NO | `wrangler secret put SECRET_NAME` |
| **Local Dev (localhost)** | ✅ YES | Create `.env.local` with values |
| **Template Repo (claude-pattern)** | ❌ NO | Documentation only |

---

## Production Secrets (Cloudflare Workers)

### How Production Secrets Work

Cloudflare Workers provide a secure secrets management system where secrets are:

1. **Stored in Cloudflare's infrastructure** (encrypted at rest)
2. **Injected at runtime** via the `env` binding
3. **Never written to disk** (only in memory)
4. **Managed per-environment** (staging vs production)

### Setting Secrets in Production

**Initial setup (one-time per secret):**

```bash
cd /path/to/your-project

# Set each secret (will prompt for value)
wrangler secret put SMTP2GO_API_KEY
wrangler secret put RESEND_API_KEY
wrangler secret put JWT_SECRET
wrangler secret put JWT_SERVICE_SECRET
wrangler secret put CRON_SECRET_TOKEN
wrangler secret put PADDLE_WEBHOOK_SECRET
wrangler secret put PADDLE_API_KEY
wrangler secret put PADDLE_CLIENT_TOKEN

# Deploy (secrets are automatically available)
wrangler deploy
```

**Verification:**

```bash
# List all secrets (doesn't show values, just names)
wrangler secret list

# Output:
# SMTP2GO_API_KEY
# RESEND_API_KEY
# JWT_SECRET
# ...
```

### Accessing Secrets in Production Code

**API Route Example:**

```typescript
// src/app/api/email/send/route.ts
import { NextRequest } from 'next/server'
import { getCloudflareContext } from '@opennextjs/cloudflare'

export async function POST(request: NextRequest) {
  // Get Cloudflare environment bindings
  const { env } = await getCloudflareContext({ async: true })

  // Access secrets via env binding
  const apiKey = env.SMTP2GO_API_KEY  // Production secret
  const jwtSecret = env.JWT_SECRET    // Production secret

  // Use secrets safely
  await sendEmail(apiKey, emailData)
}
```

**Webhook Handler Example:**

```typescript
// src/app/api/paddle/webhook/route.ts
import { NextRequest } from 'next/server'
import { getCloudflareContext } from '@opennextjs/cloudflare'

export async function POST(request: NextRequest) {
  const { env } = await getCloudflareContext({ async: true })

  // Verify webhook signature using secret
  const isValid = verifyPaddleSignature(
    request,
    env.PADDLE_WEBHOOK_SECRET  // Cloudflare secret
  )

  if (!isValid) {
    return new Response('Invalid signature', { status: 401 })
  }

  // Process webhook...
}
```

### Production Deployment Checklist

Before deploying to production:

- [ ] All required secrets set via `wrangler secret put`
- [ ] Secrets verified with `wrangler secret list`
- [ ] No .env.local in production build (gitignored)
- [ ] Code uses `env.SECRET_NAME` pattern
- [ ] Deployed with `wrangler deploy`
- [ ] Secrets accessible in deployed app (test endpoints)

---

## Local Development Secrets (.env.local)

### Why Local Dev Needs .env.local

**The fundamental issue:**

- **Production runtime**: Cloudflare Workers (V8 isolates, has `env` binding)
- **Local dev runtime**: Node.js (via `npm run dev`, NO `env` binding)

When you run `npm run dev`, the Next.js development server runs on Node.js, which **cannot access Cloudflare Workers bindings**. Therefore, you need `.env.local` to provide secrets to Node.js via `process.env`.

### Creating .env.local for Local Development

**Step 1: Create the file**

```bash
cd /path/to/your-project

# Create .env.local (make sure it's gitignored!)
touch .env.local

# Verify it's gitignored
git status | grep .env.local  # Should return nothing
```

**Step 2: Populate with secrets**

Choose one method:

**Method A: Retrieve from Cloudflare (recommended)**

```bash
# Get each secret from production
wrangler secret get SMTP2GO_API_KEY
# Copy the output and add to .env.local:
# SMTP2GO_API_KEY=api-ABC123XYZ...

wrangler secret get RESEND_API_KEY
# Copy to .env.local:
# RESEND_API_KEY=re_ABC123XYZ...

# Repeat for all secrets
```

**Method B: Use vault sync script (if using claude-pattern)**

```bash
# Sync from template vault
.claude/scripts/sync-secrets.sh --sandbox ~/Developer/Private/your-project

# Verify
ls -la .env.local  # Should exist with 600 permissions
```

**Method C: Copy from service dashboards**

1. **SMTP2GO**: https://app.smtp2go.com/settings/apikeys/
2. **Resend**: https://resend.com/api-keys
3. **Paddle**: https://vendors.paddle.com/ → Developer Tools → Authentication

Copy API keys into `.env.local`:

```bash
# .env.local
SMTP2GO_API_KEY=api-YOUR_KEY_HERE
RESEND_API_KEY=re_YOUR_KEY_HERE
PADDLE_API_KEY=pdl_YOUR_KEY_HERE
PADDLE_CLIENT_TOKEN=YOUR_TOKEN_HERE
PADDLE_WEBHOOK_SECRET=whsec_YOUR_SECRET_HERE
JWT_SECRET=YOUR_JWT_SECRET_HERE
JWT_SERVICE_SECRET=YOUR_SERVICE_SECRET_HERE
CRON_SECRET_TOKEN=YOUR_CRON_TOKEN_HERE
```

**Step 3: Verify permissions**

```bash
# Secure the file
chmod 600 .env.local

# Verify
ls -la .env.local
# Should show: -rw------- (owner read/write only)
```

**Step 4: Verify gitignore**

```bash
# Check .gitignore includes .env.local
cat .gitignore | grep .env.local

# Verify not tracked
git status | grep .env.local  # Should return nothing
```

### Accessing Secrets in Local Development

The **same code** works in both environments using the fallback pattern:

```typescript
// Fallback pattern: Try Cloudflare env first, fall back to process.env
const apiKey = env?.SMTP2GO_API_KEY || process.env.SMTP2GO_API_KEY

// Production (Cloudflare Workers):
//   - env.SMTP2GO_API_KEY exists (Cloudflare secret)
//   - Returns Cloudflare secret

// Local Development (npm run dev):
//   - env is undefined (no Cloudflare binding in Node.js)
//   - Falls back to process.env.SMTP2GO_API_KEY (.env.local)
//   - Returns .env.local value
```

### Local Development Checklist

Before running `npm run dev`:

- [ ] `.env.local` created in project root
- [ ] All required secrets populated
- [ ] File permissions set to 600
- [ ] `.env.local` is in `.gitignore`
- [ ] `git status` shows nothing about .env.local
- [ ] Code uses fallback pattern: `env?.SECRET || process.env.SECRET`

---

## Code Patterns for Universal Compatibility

### Best Practice: Fallback Pattern

**Always use this pattern** for secrets that need to work in both environments:

```typescript
import { NextRequest } from 'next/server'
import { getCloudflareContext } from '@opennextjs/cloudflare'

export async function POST(request: NextRequest) {
  const { env } = await getCloudflareContext({ async: true })

  // ✅ GOOD: Fallback pattern (works everywhere)
  const smtpKey = env?.SMTP2GO_API_KEY || process.env.SMTP2GO_API_KEY
  const jwtSecret = env?.JWT_SECRET || process.env.JWT_SECRET
  const paddleKey = env?.PADDLE_API_KEY || process.env.PADDLE_API_KEY

  // Use secrets normally
  await sendEmail(smtpKey, emailData)
  const token = signJWT(jwtSecret, payload)
}
```

### Bad Patterns to Avoid

**❌ BAD: Production-only (breaks local dev)**

```typescript
// This ONLY works in production, not in local dev
const apiKey = env.SMTP2GO_API_KEY  // env is undefined locally!
```

**❌ BAD: Local-only (ignores Cloudflare secrets)**

```typescript
// This works locally but ignores production Cloudflare secrets
const apiKey = process.env.SMTP2GO_API_KEY  // No Cloudflare secret!
```

**❌ BAD: Wrong fallback order**

```typescript
// This uses local .env even in production (security risk!)
const apiKey = process.env.SMTP2GO_API_KEY || env?.SMTP2GO_API_KEY
```

### Real-World Example from hivetechs-website

**Email Service Implementation:**

```typescript
// src/lib/email-smtp2go.ts
export class SMTP2GOEmailService {
  private env?: CloudflareEnv

  constructor(env?: CloudflareEnv) {
    this.env = env
  }

  private getApiKey(): string | undefined {
    // ✅ Fallback pattern: production first, local second
    return this.env?.SMTP2GO_API_KEY || process.env.SMTP2GO_API_KEY
  }

  async sendEmail(emailData: EmailData) {
    const apiKey = this.getApiKey()
    if (!apiKey) {
      throw new Error('SMTP2GO_API_KEY not configured')
    }

    // Use API key for sending...
  }
}
```

**Usage in API Route:**

```typescript
// src/app/api/email/send-magic-link/route.ts
export async function POST(request: NextRequest) {
  // Get Cloudflare context (if available)
  const { env } = await getCloudflareContext({ async: true })

  // Initialize service with fallback support
  const emailService = new SMTP2GOEmailService(env)

  // Works in both production and local dev!
  await emailService.sendEmail(emailData)
}
```

---

## Team Onboarding Workflow

### For New Team Members

**Step 1: Get access to Cloudflare**

1. Request Cloudflare account access from team lead
2. Get added to the Workers project
3. Install Wrangler: `npm install -g wrangler`
4. Authenticate: `wrangler login`

**Step 2: Retrieve production secrets for local dev**

```bash
# Clone the repository
git clone https://github.com/your-org/your-project.git
cd your-project

# Install dependencies
npm install

# Create .env.local
touch .env.local

# Retrieve secrets from Cloudflare
wrangler secret get SMTP2GO_API_KEY      # Copy to .env.local
wrangler secret get RESEND_API_KEY       # Copy to .env.local
wrangler secret get JWT_SECRET           # Copy to .env.local
wrangler secret get JWT_SERVICE_SECRET   # Copy to .env.local
wrangler secret get CRON_SECRET_TOKEN    # Copy to .env.local
wrangler secret get PADDLE_WEBHOOK_SECRET # Copy to .env.local
wrangler secret get PADDLE_API_KEY       # Copy to .env.local

# Secure the file
chmod 600 .env.local

# Verify not tracked
git status | grep .env.local  # Should return nothing
```

**Step 3: Test local development**

```bash
# Start development server
npm run dev

# Test endpoints that use secrets
curl -X POST http://localhost:3001/api/email/test \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com"}'

# Should work with .env.local secrets!
```

### For Team Lead: Setting Up New Environment

**Production environment setup:**

```bash
# Set all production secrets
wrangler secret put SMTP2GO_API_KEY
wrangler secret put RESEND_API_KEY
wrangler secret put JWT_SECRET
wrangler secret put JWT_SERVICE_SECRET
wrangler secret put CRON_SECRET_TOKEN
wrangler secret put PADDLE_WEBHOOK_SECRET
wrangler secret put PADDLE_API_KEY
wrangler secret put PADDLE_CLIENT_TOKEN

# Verify
wrangler secret list

# Deploy
wrangler deploy

# Test production endpoints
curl https://hivetechs.io/api/health
```

**Staging environment setup:**

```bash
# Set staging-specific secrets (use different values!)
wrangler secret put SMTP2GO_API_KEY --env staging
wrangler secret put PADDLE_API_KEY --env staging  # Sandbox key

# Deploy to staging
wrangler deploy --env staging
```

---

## Common Pitfalls and Solutions

### Pitfall 1: "env is undefined" in Local Dev

**Symptom:**

```
TypeError: Cannot read property 'SMTP2GO_API_KEY' of undefined
```

**Cause:** Using `env.SECRET_NAME` without fallback in local development.

**Solution:** Always use fallback pattern:

```typescript
// ❌ BAD
const apiKey = env.SMTP2GO_API_KEY

// ✅ GOOD
const apiKey = env?.SMTP2GO_API_KEY || process.env.SMTP2GO_API_KEY
```

### Pitfall 2: ".env.local Not Working" in Production

**Symptom:** Secrets work locally but fail in production.

**Cause:** Forgot to set Cloudflare secrets.

**Solution:**

```bash
# Set secrets in Cloudflare
wrangler secret put SMTP2GO_API_KEY
wrangler secret put JWT_SECRET
# etc...

# Re-deploy
wrangler deploy
```

### Pitfall 3: "Secrets Committed to Git"

**Symptom:** `.env.local` appears in `git status`.

**Cause:** `.env.local` not in `.gitignore`.

**Solution:**

```bash
# Add to .gitignore
echo ".env.local" >> .gitignore

# Remove from git cache
git rm -r --cached .env.local

# Verify
git status | grep .env.local  # Should return nothing

# IMPORTANT: Rotate all committed secrets immediately!
```

### Pitfall 4: "Wrong Secret Used in Production"

**Symptom:** Production uses .env.local values instead of Cloudflare secrets.

**Cause:** Wrong fallback order in code.

**Solution:**

```typescript
// ❌ BAD: process.env takes precedence
const apiKey = process.env.SMTP2GO_API_KEY || env?.SMTP2GO_API_KEY

// ✅ GOOD: Cloudflare env takes precedence
const apiKey = env?.SMTP2GO_API_KEY || process.env.SMTP2GO_API_KEY
```

### Pitfall 5: "Team Member Can't Access Secrets"

**Symptom:** New team member can't retrieve secrets via `wrangler secret get`.

**Cause:** Not added to Cloudflare Workers project.

**Solution:**

1. Team lead: Go to Cloudflare dashboard
2. Workers & Pages → Select project
3. Settings → Permissions
4. Add team member with appropriate role
5. Team member: Run `wrangler login` again

---

## Security Best Practices

### 1. Never Commit Secrets to Git

**Prevention:**

```bash
# Always check before committing
git status | grep -E ".env|secret|key"

# Should return nothing if safe

# Verify .gitignore
cat .gitignore | grep .env

# Should include:
# .env.local
# .env*.local
```

### 2. Use Different Secrets for Each Environment

```bash
# Production
wrangler secret put PADDLE_API_KEY
# Enter production API key: pdl_live_abc123...

# Staging
wrangler secret put PADDLE_API_KEY --env staging
# Enter sandbox API key: pdl_sdbx_xyz789...
```

### 3. Rotate Secrets Regularly

**Recommended schedule:**

- **Quarterly**: Rotate Paddle API keys, JWT secrets
- **Annually**: Rotate email service keys
- **Immediately**: If any secret is compromised

**Rotation procedure:**

```bash
# 1. Generate new secret in service dashboard
# 2. Update Cloudflare
wrangler secret put SMTP2GO_API_KEY
# 3. Update local .env.local
# 4. Re-deploy
wrangler deploy
# 5. Verify new secret works
# 6. Revoke old secret in service dashboard
```

### 4. Secure .env.local Permissions

```bash
# Always set restrictive permissions
chmod 600 .env.local

# Verify
ls -la .env.local
# Should show: -rw------- (owner only)
```

### 5. Use Cloudflare Access Control

**For production secrets:**

1. Cloudflare dashboard → Workers & Pages → Your Project
2. Settings → Permissions
3. Limit access to:
   - Admins: Full access (read/write secrets)
   - Developers: Deploy access (no secret visibility)
   - Viewers: Read-only (no secret access)

### 6. Audit Secret Access

**Regular checks:**

```bash
# List all secrets (names only, no values)
wrangler secret list

# Check who has access
# Cloudflare dashboard → Audit Logs

# Review API usage
# Service dashboards (SMTP2GO, Paddle, etc.)
```

### 7. Handle Secrets in Code Safely

**✅ GOOD:**

```typescript
// Secrets only in memory, never logged
const apiKey = env?.SMTP2GO_API_KEY || process.env.SMTP2GO_API_KEY
await sendEmail(apiKey, data)
```

**❌ BAD:**

```typescript
// NEVER log secrets!
console.log('API Key:', env.SMTP2GO_API_KEY)  // Security risk!

// NEVER expose in responses
return Response.json({ apiKey: env.SMTP2GO_API_KEY })  // Critical vulnerability!

// NEVER store in client-side code
const apiKey = process.env.NEXT_PUBLIC_API_KEY  // Exposed to browsers!
```

---

## Conclusion

**Key Takeaways:**

1. **Production** = Cloudflare secrets via `wrangler secret put` (NO .env files)
2. **Local Dev** = `.env.local` with secrets (for Node.js runtime)
3. **Always** use fallback pattern: `env?.SECRET || process.env.SECRET`
4. **Never** commit .env.local to git
5. **Rotate** secrets regularly
6. **Restrict** access to production secrets

**Quick Reference Commands:**

```bash
# Production setup
wrangler secret put SECRET_NAME
wrangler deploy

# Local development setup
touch .env.local
wrangler secret get SECRET_NAME  # Copy to .env.local
npm run dev

# Verification
wrangler secret list              # List production secrets
git status | grep .env.local      # Should be empty (gitignored)
```

---

**Last Updated**: 2025-10-09
**Maintained By**: Verone Lazio
**Next Review**: 2026-01-09 (quarterly)
