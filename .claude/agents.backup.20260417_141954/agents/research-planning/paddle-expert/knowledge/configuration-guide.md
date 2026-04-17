# Paddle Configuration Guide

**Complete setup guide for Paddle.com billing integration**

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Paddle Dashboard Setup](#paddle-dashboard-setup)
4. [Environment Configuration](#environment-configuration)
5. [Cloudflare Workers Deployment](#cloudflare-workers-deployment)
6. [Testing & Validation](#testing--validation)
7. [Production Deployment](#production-deployment)
8. [Troubleshooting](#troubleshooting)

---

## Overview

This guide walks you through configuring Paddle.com billing for your Next.js
application deployed on Cloudflare Workers.

**Configuration Files:**

- **Template**: `.env.paddle.example` (in repository root)
- **Development**: `.env.local` (local development, not committed)
- **Production**: `wrangler.toml` + Cloudflare secrets

**Key Concepts:**

- **Vendor ID**: Your Paddle account identifier (public, safe to expose)
- **API Key**: Server-side authentication for Paddle API (SECRET)
- **Client Token**: Frontend authentication for Paddle.js (public)
- **Webhook Secret**: HMAC signature verification (CRITICAL SECRET)
- **Price IDs**: Product pricing identifiers from Paddle Catalog

---

## Prerequisites

### 1. Paddle Account Setup

**Sandbox Account (Development):**

- Sign up: https://sandbox-vendors.paddle.com/signup
- Verify email address
- Complete business profile (can use test data)
- Note: Sandbox is completely separate from production

**Production Account (When Ready):**

- Sign up: https://vendors.paddle.com/signup
- Complete full business verification
- Add bank account for payouts
- Configure tax settings

### 2. Domain Configuration

**Email Domain Verification:**

1. Navigate to: Paddle Dashboard → Settings → Email Settings
2. Add your domain (e.g., hivetechs.io)
3. Add DNS TXT record provided by Paddle
4. Wait for verification (can take up to 24 hours)
5. Set as default email domain

**Webhook Endpoint Requirements:**

- Must be publicly accessible HTTPS URL
- Must respond to POST requests
- Must return 200 OK within 10 seconds
- Must verify webhook signatures (HMAC-SHA256)

---

## Paddle Dashboard Setup

### Step 1: Get Vendor ID

**Location:** Paddle Dashboard → Developer Tools → Authentication

1. Log into Paddle Dashboard (sandbox or production)
2. Navigate to "Developer Tools" in left sidebar
3. Click "Authentication"
4. Copy your **Vendor ID** (e.g., 232110)

**Environment Variables:**

```bash
PADDLE_VENDOR_ID=232110
NEXT_PUBLIC_PADDLE_VENDOR_ID=232110
```

### Step 2: Generate API Key

**Location:** Paddle Dashboard → Developer Tools → Authentication → API Keys

1. In Authentication page, scroll to "API Keys" section
2. Click "Create New Key"
3. Give it a descriptive name:
   - Sandbox: "Development Server API Key"
   - Production: "Production Server API Key"
4. Copy the key immediately (only shown once!)

**Permissions Required:**

- Read subscriptions
- Write subscriptions
- Read customers
- Write customers
- Read transactions
- Read prices

**Environment Variables:**

```bash
# Option 1: Single API key (switch via PADDLE_ENVIRONMENT)
PADDLE_API_KEY=your_key_here

# Option 2: Separate keys (recommended)
PADDLE_SANDBOX_API_KEY=sandbox_key_here
PADDLE_PRODUCTION_API_KEY=production_key_here
```

**Security:**

- ❌ NEVER commit API keys to git
- ❌ NEVER expose in frontend code
- ✅ Use Cloudflare secrets for production
- ✅ Store in .env.local for development

### Step 3: Generate Client-Side Token

**Location:** Paddle Dashboard → Developer Tools → Authentication → Client-side
tokens

1. In Authentication page, scroll to "Client-side tokens" section
2. Click "Create New Token"
3. Name it descriptively:
   - Sandbox: "Development Frontend Token"
   - Production: "Production Frontend Token"
4. Copy the token

**Token Format:**

- Sandbox: `test_XXXXXXXXXXXXXXXXXXXXXXXX`
- Production: `live_XXXXXXXXXXXXXXXXXXXXXXXX`

**Environment Variables:**

```bash
NEXT_PUBLIC_PADDLE_CLIENT_TOKEN=test_78f1193c72d118ad70ed5b2c2f2
```

**Security:**

- ✅ Safe to expose in frontend (designed for client-side use)
- ✅ Can be committed to git (in wrangler.toml vars)
- ✅ Rate-limited by Paddle automatically

### Step 4: Create Products and Prices

**Location:** Paddle Dashboard → Catalog → Products

**For Subscription Plans:**

1. Click "Create Product"
2. Fill in product details:
   - **Name**: Basic Plan
   - **Description**: Limited usage, basic support
   - **Tax Category**: Standard (or your category)
3. Click "Create Product"
4. In the product page, scroll to "Prices" section
5. Click "Add Price"
6. Configure pricing:
   - **Billing Type**: Recurring
   - **Billing Cycle**: Monthly (or your preference)
   - **Unit Price**: $5.00 USD
   - **Trial Period**: 7 days (optional)
7. Click "Add Price"
8. Copy the **Price ID** (format: `pri_XXXXXXXXXXXXXXXXXXXXXXXXXX`)

**Repeat for all subscription tiers:**

- Basic ($5/month) → `PADDLE_PRICE_BASIC`
- Standard ($10/month) → `PADDLE_PRICE_STANDARD`
- Premium ($20/month) → `PADDLE_PRICE_PREMIUM`
- Unlimited ($30/month) → `PADDLE_PRICE_UNLIMITED`
- Team ($115/month) → `PADDLE_PRICE_TEAM`

**For One-Time Credit Packs:**

1. Click "Create Product"
2. Fill in details:
   - **Name**: 25 Credits
   - **Description**: One-time credit pack
   - **Tax Category**: Standard
3. Click "Add Price"
4. Configure pricing:
   - **Billing Type**: One-time
   - **Unit Price**: $3.00 USD
5. Copy the **Price ID**

**Repeat for all credit packs:**

- 25 Credits ($3) → `PADDLE_PRICE_CREDITS_25`
- 75 Credits ($7) → `PADDLE_PRICE_CREDITS_75`
- 200 Credits ($15) → `PADDLE_PRICE_CREDITS_200`

**Environment Variables:**

```bash
PADDLE_PRICE_BASIC=pri_01abc123...
PADDLE_PRICE_STANDARD=pri_01def456...
PADDLE_PRICE_PREMIUM=pri_01ghi789...
PADDLE_PRICE_UNLIMITED=pri_01jkl012...
PADDLE_PRICE_TEAM=pri_01mno345...
PADDLE_PRICE_CREDITS_25=pri_01pqr678...
PADDLE_PRICE_CREDITS_75=pri_01stu901...
PADDLE_PRICE_CREDITS_200=pri_01vwx234...
```

**Important Notes:**

- Price IDs are DIFFERENT in sandbox vs production
- You must create products in BOTH environments
- Price IDs never change once created
- You can have multiple prices per product (e.g., monthly/yearly)

### Step 5: Configure Webhook

**Location:** Paddle Dashboard → Developer Tools → Notifications

**Create Webhook:**

1. Navigate to "Developer Tools" → "Notifications"
2. Click "Create Notification Destination"
3. Configure webhook:
   - **Destination URL**: `https://yourdomain.com/api/paddle/webhook`
   - **Description**: Production Webhook (or Sandbox Webhook)
   - **API Version**: 1 (latest)
4. Select events to subscribe to:
   - ✅ `subscription.created`
   - ✅ `subscription.updated`
   - ✅ `subscription.activated`
   - ✅ `subscription.canceled`
   - ✅ `subscription.past_due`
   - ✅ `subscription.paused`
   - ✅ `subscription.resumed`
   - ✅ `transaction.completed`
   - ✅ `transaction.updated`
   - ✅ `transaction.payment_failed`
   - ✅ `customer.created`
   - ✅ `customer.updated`
5. Click "Create"

**Get Webhook Credentials:**

1. After creation, click on your webhook
2. Copy the **Notification Destination ID**:
   - Format: `ntfset_XXXXXXXXXXXXXXXXXXXXXXXXXX`
   - This is your `PADDLE_WEBHOOK_ID`
3. Click "Show Secret Key"
4. Copy the **Secret Key**:
   - Format: `pdl_ntfset_...`
   - This is your `PADDLE_WEBHOOK_SECRET`

**Environment Variables:**

```bash
# Webhook IDs (safe to expose, used for logging)
PADDLE_WEBHOOK_ID_SANDBOX=ntfset_01jxvaqejk038xjx7gn7qc8br7
PADDLE_WEBHOOK_ID_PRODUCTION=ntfset_01jxts5prxmd9y82gh5frmkhhf
PADDLE_WEBHOOK_ID=ntfset_01jxts5prxmd9y82gh5frmkhhf

# Webhook Secret (CRITICAL SECRET - signature verification)
PADDLE_WEBHOOK_SECRET=pdl_ntfset_abc123...
```

**Security Requirements:**

- ❌ NEVER commit webhook secret to git
- ❌ NEVER expose in frontend or logs
- ✅ Store in Cloudflare secrets for production
- ✅ Verify signature on EVERY webhook request
- ✅ Reject requests with invalid signatures (401 Unauthorized)

**Test Webhook:**

1. In Paddle Dashboard webhook settings, find "Test Webhook"
2. Click "Send Test Event"
3. Select event type (e.g., `subscription.created`)
4. Click "Send"
5. Verify your endpoint:
   - Receives POST request
   - Returns 200 OK
   - Appears in webhook logs

---

## Environment Configuration

### Development Setup (.env.local)

**Step 1: Copy Template**

```bash
cp .env.paddle.example .env.local
```

**Step 2: Fill in Sandbox Values**

```bash
# API Credentials
PADDLE_VENDOR_ID=232110
PADDLE_SANDBOX_API_KEY=your_sandbox_api_key_here
PADDLE_ENVIRONMENT=sandbox

# Webhook Configuration
PADDLE_WEBHOOK_ID=ntfset_01jxvaqejk038xjx7gn7qc8br7
PADDLE_WEBHOOK_SECRET=your_sandbox_webhook_secret_here

# Client-Side Configuration
NEXT_PUBLIC_PADDLE_VENDOR_ID=232110
NEXT_PUBLIC_PADDLE_ENVIRONMENT=sandbox
NEXT_PUBLIC_PADDLE_CLIENT_TOKEN=test_your_token_here

# Product Price IDs (from Paddle Sandbox)
PADDLE_PRICE_BASIC=pri_01sandbox_basic
PADDLE_PRICE_STANDARD=pri_01sandbox_standard
# ... etc

# Feature Flags
NEXT_PUBLIC_ENABLE_CHECKOUT=true
NEXT_PUBLIC_ENABLE_SIGNUP=true
```

**Step 3: Verify Configuration**

```bash
# Run validation script
scripts/validate-paddle-config.sh

# Expected output:
# ✅ All required Paddle variables are set
```

### Environment Variable Reference

| Variable                          | Type   | Required | Description                                 |
| --------------------------------- | ------ | -------- | ------------------------------------------- |
| `PADDLE_VENDOR_ID`                | Public | Yes      | Your Paddle account ID                      |
| `PADDLE_API_KEY`                  | SECRET | Yes\*    | API key (if using single key)               |
| `PADDLE_SANDBOX_API_KEY`          | SECRET | Yes\*    | Sandbox API key (if using separate keys)    |
| `PADDLE_PRODUCTION_API_KEY`       | SECRET | Yes\*    | Production API key (if using separate keys) |
| `PADDLE_ENVIRONMENT`              | Public | Yes      | "sandbox" or "production"                   |
| `PADDLE_WEBHOOK_ID`               | Public | Yes      | Webhook destination ID                      |
| `PADDLE_WEBHOOK_SECRET`           | SECRET | Yes      | Webhook signature verification key          |
| `NEXT_PUBLIC_PADDLE_VENDOR_ID`    | Public | Yes      | Vendor ID for frontend                      |
| `NEXT_PUBLIC_PADDLE_ENVIRONMENT`  | Public | Yes      | Environment for frontend                    |
| `NEXT_PUBLIC_PADDLE_CLIENT_TOKEN` | Public | Yes      | Client-side token for Paddle.js             |
| `PADDLE_PRICE_*`                  | Public | No\*\*   | Product price IDs                           |
| `NEXT_PUBLIC_ENABLE_CHECKOUT`     | Public | No       | Enable/disable checkout                     |
| `NEXT_PUBLIC_ENABLE_SIGNUP`       | Public | No       | Enable/disable signup                       |

\* Choose either single API key or separate sandbox/production keys \*\*
Required if using checkout functionality

---

## Production vs Local Development: Secrets Management

### Understanding the Distinction

**CRITICAL**: Production (Cloudflare Workers) and local development (npm run
dev) handle secrets completely differently!

#### Production (Cloudflare Workers)

**Runtime**: Cloudflare Workers (V8 isolates) **Secrets Storage**: Cloudflare
secrets (via `wrangler secret put`) **Access Pattern**: `env.SECRET_NAME` **NO
.env files needed!**

```bash
# Set secrets in Cloudflare (one-time)
wrangler secret put PADDLE_API_KEY
wrangler secret put PADDLE_WEBHOOK_SECRET

# Deploy (secrets automatically available)
wrangler deploy
```

**Code access in production:**

```typescript
export async function POST(request: NextRequest) {
  const { env } = await getCloudflareContext({ async: true });

  // Access Cloudflare secrets
  const apiKey = env.PADDLE_API_KEY; // Cloudflare secret
  const webhookSecret = env.PADDLE_WEBHOOK_SECRET; // Cloudflare secret
}
```

#### Local Development (npm run dev)

**Runtime**: Node.js (via Next.js dev server) **Secrets Storage**: `.env.local`
file (gitignored) **Access Pattern**: `process.env.SECRET_NAME` **REQUIRES
.env.local with actual values!**

```bash
# Create .env.local for local testing
touch .env.local

# Retrieve secrets from Cloudflare or service dashboards
wrangler secret get PADDLE_API_KEY  # Copy output to .env.local

# Or use sync script
.claude/scripts/sync-secrets.sh --sandbox ~/Developer/Private/your-project

# Run local dev server
npm run dev
```

**.env.local example:**

```bash
PADDLE_API_KEY=pdl_sdbx_apikey_abc123...
PADDLE_WEBHOOK_SECRET=pdl_ntfset_xyz789...
JWT_SECRET=your_jwt_secret_here
```

#### Universal Code Pattern (Works in Both Environments!)

**Always use the fallback pattern:**

```typescript
import { getCloudflareContext } from '@opennextjs/cloudflare';

export async function POST(request: NextRequest) {
  // Get Cloudflare context (may be undefined locally)
  const { env } = await getCloudflareContext({ async: true });

  // ✅ GOOD: Fallback pattern
  const apiKey = env?.PADDLE_API_KEY || process.env.PADDLE_API_KEY;
  const webhookSecret =
    env?.PADDLE_WEBHOOK_SECRET || process.env.PADDLE_WEBHOOK_SECRET;

  // Production (Cloudflare Workers):
  //   - env.PADDLE_API_KEY exists → uses Cloudflare secret

  // Local Dev (npm run dev):
  //   - env is undefined → falls back to process.env.PADDLE_API_KEY (.env.local)

  // Use secrets normally
  await verifyWebhook(webhookSecret, request);
}
```

#### Common Mistakes to Avoid

❌ **BAD: Production-only (breaks local dev)**

```typescript
const apiKey = env.PADDLE_API_KEY; // undefined locally!
```

❌ **BAD: Local-only (ignores Cloudflare)**

```typescript
const apiKey = process.env.PADDLE_API_KEY; // no Cloudflare secret!
```

❌ **BAD: Wrong fallback order**

```typescript
const apiKey = process.env.PADDLE_API_KEY || env?.PADDLE_API_KEY; // uses local even in production!
```

#### Decision Guide: Do I Need .env.local?

```
Are you deploying to Cloudflare Workers production?
├─ Yes → Use wrangler secret put
│         NO .env.local needed
│         Secrets accessed via: env.PADDLE_API_KEY
│
└─ No → Running locally (npm run dev)?
    ├─ Yes → CREATE .env.local
    │         Populate with secrets
    │         Secrets accessed via: process.env.PADDLE_API_KEY
    │
    └─ No → Template repository?
              NO secrets needed (documentation only)
```

#### Quick Reference Table

| Environment                        | Secrets Storage    | Access Pattern               | Need .env.local? |
| ---------------------------------- | ------------------ | ---------------------------- | ---------------- |
| **Production (hivetechs.io)**      | Cloudflare secrets | `env.PADDLE_API_KEY`         | ❌ NO            |
| **Local Dev (localhost)**          | `.env.local` file  | `process.env.PADDLE_API_KEY` | ✅ YES           |
| **Template Repo (claude-pattern)** | Documentation only | N/A                          | ❌ NO            |

#### Where to Get Secrets for Local Development

**Option 1: Retrieve from Cloudflare (recommended)**

```bash
wrangler secret get PADDLE_API_KEY
wrangler secret get PADDLE_WEBHOOK_SECRET
# Copy outputs to .env.local
```

**Option 2: Copy from Paddle Dashboard**

- Paddle: https://vendors.paddle.com/ → Developer Tools → Authentication
- Copy API keys and webhook secret
- Add to `.env.local`

**Option 3: Use template vault sync script**

```bash
.claude/scripts/sync-secrets.sh --sandbox ~/Developer/Private/your-project
```

#### Security Checklist

Production:

- [ ] All secrets set via `wrangler secret put`
- [ ] NO .env.local in production build (gitignored)
- [ ] Code uses fallback pattern: `env?.SECRET || process.env.SECRET`

Local Development:

- [ ] `.env.local` created in project root
- [ ] All required secrets populated
- [ ] `.env.local` is gitignored
- [ ] File permissions set to 600

**For complete secrets architecture details, see**:
`.claude/docs/CLOUDFLARE_SECRETS_ARCHITECTURE.md`

---

## Cloudflare Workers Deployment

### Step 1: Configure wrangler.toml

**Add Public Variables:**

```toml
# Production Environment Variables
[vars]
ENVIRONMENT = "production"
NEXT_PUBLIC_SITE_URL = "https://yourdomain.com"

# Paddle Public Configuration
NEXT_PUBLIC_PADDLE_VENDOR_ID = "232110"
NEXT_PUBLIC_PADDLE_ENVIRONMENT = "production"
NEXT_PUBLIC_PADDLE_CLIENT_TOKEN = "live_78f1193c72d118ad70ed5b2c2f2"
PADDLE_WEBHOOK_ID = "ntfset_01jxts5prxmd9y82gh5frmkhhf"
PADDLE_ENVIRONMENT = "production"

# Feature Flags
NEXT_PUBLIC_ENABLE_CHECKOUT = "true"
NEXT_PUBLIC_ENABLE_SIGNUP = "true"
```

**Important:**

- Only put PUBLIC variables in `wrangler.toml`
- NEVER put secrets in `wrangler.toml` (they'll be committed to git!)
- `NEXT_PUBLIC_*` variables are exposed to frontend (safe)

### Step 2: Set Cloudflare Secrets

**Set Secrets via CLI:**

```bash
# Navigate to your project directory
cd /path/to/your/project

# Set Paddle API key (choose one pattern)

# Pattern 1: Single API key
wrangler secret put PADDLE_API_KEY
# When prompted, paste your production API key

# Pattern 2: Separate sandbox/production keys (recommended)
wrangler secret put PADDLE_SANDBOX_API_KEY
# Paste sandbox key

wrangler secret put PADDLE_PRODUCTION_API_KEY
# Paste production key

# Set webhook secret (CRITICAL)
wrangler secret put PADDLE_WEBHOOK_SECRET
# Paste webhook secret key
```

**Verify Secrets Are Set:**

```bash
wrangler secret list

# Expected output:
# PADDLE_API_KEY (or PADDLE_PRODUCTION_API_KEY)
# PADDLE_WEBHOOK_SECRET
# ... (your other secrets)
```

**Important Notes:**

- Secrets are encrypted and stored securely by Cloudflare
- Secrets are NOT visible in dashboard or wrangler.toml
- Secrets are environment-specific (set separately for staging/production)
- To update a secret, use `wrangler secret put` again

### Step 3: Deploy to Cloudflare

**Build and Deploy:**

```bash
# Build Next.js for Cloudflare Workers
npm run build

# Deploy to Cloudflare
wrangler deploy
```

**Verify Deployment:**

```bash
# Check deployment status
wrangler deployments list

# Test webhook endpoint (should return 401 without valid signature)
curl -X POST https://yourdomain.com/api/paddle/webhook \
  -H "Content-Type: application/json" \
  -d '{"test":"data"}'

# Expected response: 401 Unauthorized (signature verification failed)
```

### Step 4: Update Paddle Webhook URL

**After First Deployment:**

1. Go to Paddle Dashboard → Developer Tools → Notifications
2. Click on your webhook
3. Update "Destination URL" to your production URL:
   - `https://yourdomain.com/api/paddle/webhook`
4. Click "Save"
5. Click "Send Test Event" to verify

**Webhook Logs:**

- View in Paddle Dashboard → Developer Tools → Events
- View in Cloudflare Dashboard → Workers & Pages → Your Worker → Logs
- Verify successful delivery (200 OK responses)

---

## Testing & Validation

### Local Development Testing

**1. Start Development Server:**

```bash
npm run dev
# Should start on localhost:3001
```

**2. Test Paddle.js Integration:**

Open your browser's developer console and check:

```javascript
// Paddle.js should load successfully
console.log(window.Paddle);

// Check environment
console.log(window.Paddle.Environment.get());
// Should show: { environment: "sandbox" }
```

**3. Test Checkout Flow (Sandbox):**

1. Navigate to your checkout page
2. Click "Subscribe" or "Buy Credits"
3. Paddle overlay should appear
4. Use Paddle test card:
   - **Card Number**: 4242 4242 4242 4242
   - **Expiry**: Any future date (e.g., 12/25)
   - **CVC**: Any 3 digits (e.g., 123)
   - **ZIP**: Any ZIP code (e.g., 10001)
5. Complete checkout
6. Verify webhook fires:
   - Check server logs for `[Paddle Webhook]` messages
   - Verify database updates (user subscription status)
   - Check email delivery (if configured)

**4. Test Webhook Signature Verification:**

```bash
# Test with invalid signature (should fail with 401)
curl -X POST http://localhost:3001/api/paddle/webhook \
  -H "Content-Type: application/json" \
  -d '{"event_type":"transaction.completed","data":{}}'

# Expected: 401 Unauthorized
```

### Production Testing

**1. Pre-Deployment Checklist:**

- [ ] All environment variables set correctly
- [ ] Cloudflare secrets configured
- [ ] Webhook URL updated to production domain
- [ ] HTTPS enforced on webhook endpoint
- [ ] Rate limiting configured
- [ ] Database migrations run
- [ ] Email service configured

**2. Smoke Tests:**

```bash
# Test webhook endpoint (should fail with 401)
curl -X POST https://yourdomain.com/api/paddle/webhook \
  -d '{"test":"data"}'

# Test checkout page loads
curl -I https://yourdomain.com/checkout/basic

# Test Paddle.js loads (check for 200 OK)
curl -I https://cdn.paddle.com/paddle/v2/paddle.js
```

**3. End-to-End Test (Sandbox First):**

1. Ensure `NEXT_PUBLIC_PADDLE_ENVIRONMENT=sandbox` in production
2. Deploy to production
3. Complete full checkout flow using test card
4. Verify:
   - Webhook fires and is logged
   - Database updates correctly
   - User receives confirmation email
   - Subscription appears in Paddle Dashboard
5. Cancel test subscription
6. Switch to `NEXT_PUBLIC_PADDLE_ENVIRONMENT=production`
7. Redeploy

**4. Production Go-Live:**

1. Switch all environment variables to production values:
   ```toml
   NEXT_PUBLIC_PADDLE_ENVIRONMENT = "production"
   PADDLE_ENVIRONMENT = "production"
   NEXT_PUBLIC_PADDLE_CLIENT_TOKEN = "live_..."
   PADDLE_WEBHOOK_ID = "ntfset_...production..."
   ```
2. Update secrets:
   ```bash
   wrangler secret put PADDLE_PRODUCTION_API_KEY
   wrangler secret put PADDLE_WEBHOOK_SECRET  # Production webhook secret
   ```
3. Deploy:
   ```bash
   wrangler deploy
   ```
4. Monitor:
   - Cloudflare logs for errors
   - Paddle Dashboard → Events for webhook delivery
   - Database for transaction records
   - Email delivery logs

### Validation Script

**Run Automated Validation:**

```bash
scripts/validate-paddle-config.sh

# Example output:
# 🔍 Validating Paddle Configuration...
# ✅ PADDLE_VENDOR_ID is set
# ✅ PADDLE_API_KEY is set
# ✅ PADDLE_WEBHOOK_SECRET is set
# ✅ NEXT_PUBLIC_PADDLE_CLIENT_TOKEN is set
# ✅ All required Paddle variables are set
```

---

## Production Deployment

### Security Best Practices

**1. Secrets Management:**

- ✅ Use Cloudflare secrets for all sensitive values
- ✅ Rotate API keys every 90 days
- ✅ Use separate keys for sandbox and production
- ✅ Never log or expose webhook secret
- ❌ Never commit secrets to git
- ❌ Never put secrets in wrangler.toml

**2. Webhook Security:**

- ✅ Verify signature on EVERY request
- ✅ Use HTTPS only (HTTP webhooks will fail)
- ✅ Respond within 10 seconds
- ✅ Implement rate limiting
- ✅ Log all webhook attempts (success and failure)
- ❌ Never process webhooks without signature verification

**3. Environment Separation:**

- ✅ Keep sandbox and production completely separate
- ✅ Test in sandbox before deploying to production
- ✅ Use different database instances
- ✅ Use different email domains if possible

**4. Error Handling:**

- ✅ Implement comprehensive error logging
- ✅ Set up monitoring alerts (Cloudflare Workers Analytics)
- ✅ Have rollback plan ready
- ✅ Test failure scenarios (payment declined, webhook failures)

### Monitoring

**1. Cloudflare Workers Logs:**

```bash
# Tail production logs
wrangler tail

# Filter for Paddle events
wrangler tail | grep -i paddle
```

**2. Paddle Dashboard Monitoring:**

- **Events**: Developer Tools → Events (webhook delivery logs)
- **Transactions**: Transactions (all payments)
- **Subscriptions**: Subscriptions (active subscriptions)
- **Customers**: Customers (user accounts)

**3. Set Up Alerts:**

- Cloudflare: Workers & Pages → Your Worker → Triggers → Alerts
- Paddle: Dashboard → Settings → Notifications
- Email: Configure alerts for failed webhooks, payment failures

**4. Health Checks:**

```bash
# Daily health check script
curl -f https://yourdomain.com/api/health || alert_team
curl -f https://yourdomain.com/api/paddle/status || alert_team
```

### Rollback Procedure

**If Issues Occur:**

1. **Immediate Rollback:**

   ```bash
   # Rollback to previous deployment
   wrangler rollback
   ```

2. **Disable Checkout Temporarily:**

   ```toml
   # In wrangler.toml
   NEXT_PUBLIC_ENABLE_CHECKOUT = "false"
   ```

   ```bash
   wrangler deploy
   ```

3. **Investigate:**
   - Check Cloudflare logs
   - Check Paddle Event logs
   - Check database for corrupted data

4. **Fix and Redeploy:**
   - Fix issue in code
   - Test in sandbox
   - Deploy to production
   - Re-enable checkout

---

## Troubleshooting

### Common Issues

#### 1. Webhook 401 Unauthorized Errors

**Symptom:** Paddle webhooks failing with 401 status

**Causes:**

- Missing `PADDLE_WEBHOOK_SECRET`
- Wrong webhook secret (sandbox vs production mismatch)
- Signature verification logic error

**Solutions:**

```bash
# Verify secret is set
wrangler secret list | grep PADDLE_WEBHOOK_SECRET

# Re-set secret if missing
wrangler secret put PADDLE_WEBHOOK_SECRET

# Check webhook signature verification code
# Ensure using correct secret for environment
const secret = env.PADDLE_WEBHOOK_SECRET;
```

**Test:**

```bash
# Webhook should fail with 401 without valid signature
curl -X POST https://yourdomain.com/api/paddle/webhook \
  -d '{"test":"data"}'
# Expected: 401 Unauthorized
```

#### 2. Paddle.js Not Loading / Checkout Not Working

**Symptom:** Paddle checkout overlay doesn't appear

**Causes:**

- Missing `NEXT_PUBLIC_PADDLE_CLIENT_TOKEN`
- Wrong environment (sandbox token in production)
- Incorrect Paddle.js initialization

**Solutions:**

```javascript
// Check browser console for errors
// Should see Paddle.js loaded successfully

// Verify environment configuration
console.log(process.env.NEXT_PUBLIC_PADDLE_ENVIRONMENT);
console.log(process.env.NEXT_PUBLIC_PADDLE_CLIENT_TOKEN);

// Check Paddle.js initialization
// In your component:
useEffect(() => {
  if (window.Paddle) {
    window.Paddle.Setup({
      vendor: parseInt(process.env.NEXT_PUBLIC_PADDLE_VENDOR_ID!),
      eventCallback: (event) => console.log('Paddle event:', event)
    });
  }
}, []);
```

**Test:**

```javascript
// In browser console
window.Paddle.Checkout.open({ product: 'your_price_id' });
// Should open Paddle overlay
```

#### 3. Wrong Environment (Sandbox vs Production)

**Symptom:** Using sandbox in production or vice versa

**Causes:**

- `PADDLE_ENVIRONMENT` doesn't match API key
- `NEXT_PUBLIC_PADDLE_ENVIRONMENT` doesn't match tokens
- Mixed sandbox and production credentials

**Solutions:**

```bash
# Verify all environment variables match:

# Server-side (Cloudflare secrets)
wrangler secret list
# Should show: PADDLE_PRODUCTION_API_KEY (not SANDBOX)

# Public variables (wrangler.toml)
grep PADDLE wrangler.toml
# Should show:
# NEXT_PUBLIC_PADDLE_ENVIRONMENT = "production"
# NEXT_PUBLIC_PADDLE_CLIENT_TOKEN = "live_..." (not "test_")
# PADDLE_ENVIRONMENT = "production"
```

**Checklist:**

- [ ] `PADDLE_ENVIRONMENT` = "production"
- [ ] `NEXT_PUBLIC_PADDLE_ENVIRONMENT` = "production"
- [ ] `NEXT_PUBLIC_PADDLE_CLIENT_TOKEN` starts with "live\_"
- [ ] Using `PADDLE_PRODUCTION_API_KEY` (not SANDBOX)
- [ ] `PADDLE_WEBHOOK_ID` is production webhook ID
- [ ] `PADDLE_WEBHOOK_SECRET` is production webhook secret

#### 4. Price Not Found / Invalid Price ID

**Symptom:** Checkout fails with "Price not found" error

**Causes:**

- Using sandbox price ID in production
- Price ID typo or incorrect value
- Price archived or deleted in Paddle Dashboard

**Solutions:**

```bash
# Verify price IDs are correct for current environment
# Sandbox price IDs: pri_01xxxsandbox
# Production price IDs: pri_01xxxproduction (different!)

# Check Paddle Dashboard:
# Catalog → Products → Your Product → Prices
# Copy exact Price ID

# Update environment variable
# .env.local (development):
PADDLE_PRICE_BASIC=pri_01abc123sandbox

# wrangler.toml (production):
# (Add to [vars] section if needed, or fetch dynamically)
```

**Test:**

```javascript
// In browser console
window.Paddle.Checkout.open({
  items: [{ priceId: 'pri_01abc123', quantity: 1 }],
});
// Should open checkout successfully
```

#### 5. Webhook Timing Out (>10 seconds)

**Symptom:** Paddle retries webhooks, logs show timeout errors

**Causes:**

- Database queries too slow
- External API calls blocking
- Complex processing in webhook handler

**Solutions:**

```typescript
// Use Cloudflare Queues for async processing
export async function POST(request: Request, { env }: { env: CloudflareEnv }) {
  // 1. Verify signature (FAST)
  const isValid = await verifyWebhookSignature(
    request,
    env.PADDLE_WEBHOOK_SECRET
  );
  if (!isValid) return new Response('Unauthorized', { status: 401 });

  // 2. Parse webhook (FAST)
  const webhook = await request.json();

  // 3. Queue for async processing (FAST)
  await env.PADDLE_WEBHOOK_QUEUE?.send(webhook);

  // 4. Respond immediately (within 1 second)
  return new Response('OK', { status: 200 });
}

// Process in queue consumer (can take longer)
```

**Optimize:**

- Use prepared statements for database queries
- Defer email sending to queue
- Cache frequently accessed data
- Minimize external API calls

#### 6. Database Not Updating After Webhook

**Symptom:** Webhook fires successfully (200 OK) but database unchanged

**Causes:**

- Database query errors (silently caught)
- Transaction rollback
- Wrong database binding

**Solutions:**

```typescript
// Add comprehensive logging
export async function POST(request: Request, { env }: { env: CloudflareEnv }) {
  try {
    const webhook = await request.json();
    console.log('[Paddle Webhook] Event:', webhook.event_type);

    // Verify database binding
    if (!env.HIVE_DB) {
      console.error('[Paddle Webhook] Database not available');
      return new Response('Database unavailable', { status: 500 });
    }

    // Update database with error handling
    const result = await env.HIVE_DB.prepare(
      `
      UPDATE users SET subscription_status = ? WHERE paddle_customer_id = ?
    `
    )
      .bind(webhook.data.status, webhook.data.customer_id)
      .run();

    console.log('[Paddle Webhook] Database update result:', result);

    if (!result.success) {
      console.error('[Paddle Webhook] Database update failed:', result.error);
      // Webhook will be retried by Paddle
      return new Response('Database error', { status: 500 });
    }

    return new Response('OK', { status: 200 });
  } catch (error) {
    console.error('[Paddle Webhook] Error:', error);
    return new Response('Internal error', { status: 500 });
  }
}
```

**Debug:**

```bash
# Check Cloudflare logs for database errors
wrangler tail | grep -i database

# Check D1 database directly
wrangler d1 execute hive-user-db --command "SELECT * FROM users WHERE paddle_customer_id = 'ctm_xxx'"
```

### Getting Help

**Resources:**

- **Paddle Documentation**: https://developer.paddle.com/
- **Paddle Support**: support@paddle.com
- **Paddle Community**: https://paddle.community/
- **Cloudflare Discord**: https://discord.gg/cloudflaredev
- **This Knowledge Base**:
  `.claude/agents/research-planning/paddle-expert/knowledge/`

**Before Asking for Help:**

1. Check this troubleshooting guide
2. Review Cloudflare logs: `wrangler tail`
3. Review Paddle Event logs: Dashboard → Developer Tools → Events
4. Verify all environment variables are set correctly
5. Test in sandbox first before production

**When Asking for Help, Include:**

- Environment (sandbox or production)
- Error message (exact text)
- Relevant logs (Cloudflare and Paddle)
- Steps to reproduce
- Expected vs actual behavior

---

## Next Steps

After completing configuration:

1. ✅ Review: [Quick Reference Guide](./quick-reference.md)
2. ✅ Complete: [Setup Checklist](./paddle-setup-checklist.md)
3. ✅ Implement: Webhook handler code
4. ✅ Test: End-to-end in sandbox
5. ✅ Deploy: To production
6. ✅ Monitor: Logs and analytics

---

**Last Updated:** 2025-10-09 **Version:** 1.0.0 **Maintainer:** paddle-expert
agent
