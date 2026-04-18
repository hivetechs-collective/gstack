# Paddle Integration Setup Checklist

**Complete step-by-step checklist for integrating Paddle.com billing into your
project**

Use this checklist when setting up Paddle in a new project. Follow steps
sequentially and check off as you complete them.

---

## Prerequisites

### Account Setup

- [ ] Paddle Sandbox account created (https://sandbox-vendors.paddle.com/signup)
- [ ] Email address verified
- [ ] Business profile completed (can use test data for sandbox)
- [ ] (Production only) Paddle Production account created
      (https://vendors.paddle.com/signup)
- [ ] (Production only) Business verification completed
- [ ] (Production only) Bank account added for payouts

### Domain Configuration

- [ ] Domain verified in Paddle Dashboard (Settings → Email Settings)
- [ ] DNS TXT record added for email verification
- [ ] Email verification confirmed (can take up to 24 hours)
- [ ] Default email domain configured

### Project Setup

- [ ] Next.js project initialized
- [ ] Cloudflare Workers deployment configured (`wrangler.toml` exists)
- [ ] D1 database created (`wrangler d1 create`)
- [ ] Environment variables file ready (`.env.local` for development)

---

## Step 1: Paddle Dashboard Configuration

### 1.1 Get Vendor ID

- [ ] Navigate to: Paddle Dashboard → Developer Tools → Authentication
- [ ] Copy **Vendor ID** (e.g., 232110)
- [ ] Save to: `PADDLE_VENDOR_ID` and `NEXT_PUBLIC_PADDLE_VENDOR_ID`

### 1.2 Generate API Key

- [ ] Navigate to: Developer Tools → Authentication → API Keys
- [ ] Click "Create New Key"
- [ ] Name: "Development Server API Key" (or "Production Server API Key")
- [ ] Select permissions:
  - [ ] Read subscriptions
  - [ ] Write subscriptions
  - [ ] Read customers
  - [ ] Write customers
  - [ ] Read transactions
  - [ ] Read prices
- [ ] Copy API key immediately (only shown once!)
- [ ] Save to: `PADDLE_SANDBOX_API_KEY` (sandbox) or `PADDLE_PRODUCTION_API_KEY`
      (production)

### 1.3 Generate Client-Side Token

- [ ] Navigate to: Developer Tools → Authentication → Client-side tokens
- [ ] Click "Create New Token"
- [ ] Name: "Development Frontend Token" (or "Production Frontend Token")
- [ ] Copy token (starts with `test_` for sandbox, `live_` for production)
- [ ] Save to: `NEXT_PUBLIC_PADDLE_CLIENT_TOKEN`

### 1.4 Create Subscription Products

For EACH subscription plan (Basic, Standard, Premium, Unlimited, Team):

- [ ] Navigate to: Catalog → Products
- [ ] Click "Create Product"
- [ ] Fill in product details:
  - [ ] Name (e.g., "Basic Plan")
  - [ ] Description (e.g., "Limited usage, basic support")
  - [ ] Tax Category (usually "Standard")
- [ ] Click "Create Product"
- [ ] In product page, click "Add Price"
- [ ] Configure pricing:
  - [ ] Billing Type: Recurring
  - [ ] Billing Cycle: Monthly (or your preference)
  - [ ] Unit Price (e.g., $5.00 USD)
  - [ ] Trial Period (optional, e.g., 7 days)
- [ ] Click "Add Price"
- [ ] Copy **Price ID** (format: `pri_XXXXXXXXX...`)
- [ ] Save to environment variable (e.g., `PADDLE_PRICE_BASIC`)

**Repeat for:**

- [ ] Basic Plan ($5/month) → `PADDLE_PRICE_BASIC`
- [ ] Standard Plan ($10/month) → `PADDLE_PRICE_STANDARD`
- [ ] Premium Plan ($20/month) → `PADDLE_PRICE_PREMIUM`
- [ ] Unlimited Plan ($30/month) → `PADDLE_PRICE_UNLIMITED`
- [ ] Team Plan ($115/month) → `PADDLE_PRICE_TEAM`

### 1.5 Create One-Time Credit Pack Products

For EACH credit pack (25, 75, 200):

- [ ] Navigate to: Catalog → Products
- [ ] Click "Create Product"
- [ ] Fill in product details:
  - [ ] Name (e.g., "25 Credits")
  - [ ] Description (e.g., "One-time credit pack")
  - [ ] Tax Category: Standard
- [ ] Click "Create Product"
- [ ] In product page, click "Add Price"
- [ ] Configure pricing:
  - [ ] Billing Type: One-time
  - [ ] Unit Price (e.g., $3.00 USD)
- [ ] Click "Add Price"
- [ ] Copy **Price ID**
- [ ] Save to environment variable

**Repeat for:**

- [ ] 25 Credits ($3) → `PADDLE_PRICE_CREDITS_25`
- [ ] 75 Credits ($7) → `PADDLE_PRICE_CREDITS_75`
- [ ] 200 Credits ($15) → `PADDLE_PRICE_CREDITS_200`

### 1.6 Configure Webhook

- [ ] Navigate to: Developer Tools → Notifications
- [ ] Click "Create Notification Destination"
- [ ] Configure webhook:
  - [ ] **Destination URL**: `https://yourdomain.com/api/paddle/webhook`
    - Note: Use your actual domain (can update after first deployment)
  - [ ] **Description**: "Production Webhook" or "Sandbox Webhook"
  - [ ] **API Version**: 1 (latest)
- [ ] Select events to subscribe to:
  - [ ] `subscription.created`
  - [ ] `subscription.updated`
  - [ ] `subscription.activated`
  - [ ] `subscription.canceled`
  - [ ] `subscription.past_due`
  - [ ] `subscription.paused`
  - [ ] `subscription.resumed`
  - [ ] `transaction.completed`
  - [ ] `transaction.updated`
  - [ ] `transaction.payment_failed`
  - [ ] `customer.created`
  - [ ] `customer.updated`
- [ ] Click "Create"
- [ ] After creation, click on your webhook
- [ ] Copy **Notification Destination ID** (format: `ntfset_XXX...`)
- [ ] Save to: `PADDLE_WEBHOOK_ID_SANDBOX` or `PADDLE_WEBHOOK_ID_PRODUCTION`
- [ ] Click "Show Secret Key"
- [ ] Copy **Secret Key** (format: `pdl_ntfset_...`)
- [ ] Save to: `PADDLE_WEBHOOK_SECRET` (NEVER commit to git!)

---

## Step 2: Environment Configuration

### 2.1 Development Environment (.env.local)

- [ ] Copy template: `cp .env.paddle.example .env.local`
- [ ] Open `.env.local` in editor
- [ ] Fill in Paddle configuration:

**API Credentials:**

- [ ] `PADDLE_VENDOR_ID` = (your vendor ID)
- [ ] `PADDLE_SANDBOX_API_KEY` = (your sandbox API key)
- [ ] `PADDLE_ENVIRONMENT` = "sandbox"

**Webhook Configuration:**

- [ ] `PADDLE_WEBHOOK_ID` = (your sandbox webhook ID)
- [ ] `PADDLE_WEBHOOK_SECRET` = (your webhook secret)

**Client-Side Configuration:**

- [ ] `NEXT_PUBLIC_PADDLE_VENDOR_ID` = (same as PADDLE_VENDOR_ID)
- [ ] `NEXT_PUBLIC_PADDLE_ENVIRONMENT` = "sandbox"
- [ ] `NEXT_PUBLIC_PADDLE_CLIENT_TOKEN` = (your sandbox client token, starts
      with `test_`)

**Product Price IDs:**

- [ ] `PADDLE_PRICE_BASIC` = (your sandbox basic plan price ID)
- [ ] `PADDLE_PRICE_STANDARD` = (your sandbox standard plan price ID)
- [ ] `PADDLE_PRICE_PREMIUM` = (your sandbox premium plan price ID)
- [ ] `PADDLE_PRICE_UNLIMITED` = (your sandbox unlimited plan price ID)
- [ ] `PADDLE_PRICE_TEAM` = (your sandbox team plan price ID)
- [ ] `PADDLE_PRICE_CREDITS_25` = (your sandbox 25 credits price ID)
- [ ] `PADDLE_PRICE_CREDITS_75` = (your sandbox 75 credits price ID)
- [ ] `PADDLE_PRICE_CREDITS_200` = (your sandbox 200 credits price ID)

**Feature Flags:**

- [ ] `NEXT_PUBLIC_ENABLE_CHECKOUT` = "true"
- [ ] `NEXT_PUBLIC_ENABLE_SIGNUP` = "true"

- [ ] Save `.env.local`
- [ ] Verify `.env.local` is in `.gitignore` (NEVER commit!)

### 2.2 Production Environment (wrangler.toml)

- [ ] Open `wrangler.toml` in editor
- [ ] Add public Paddle variables to `[vars]` section:

```toml
[vars]
ENVIRONMENT = "production"
NEXT_PUBLIC_SITE_URL = "https://yourdomain.com"

# Paddle Public Configuration
NEXT_PUBLIC_PADDLE_VENDOR_ID = "232110"
NEXT_PUBLIC_PADDLE_ENVIRONMENT = "production"
NEXT_PUBLIC_PADDLE_CLIENT_TOKEN = "live_your_token_here"
PADDLE_WEBHOOK_ID = "ntfset_your_production_webhook_id"
PADDLE_ENVIRONMENT = "production"

# Feature Flags
NEXT_PUBLIC_ENABLE_CHECKOUT = "true"
NEXT_PUBLIC_ENABLE_SIGNUP = "true"
```

- [ ] Save `wrangler.toml`
- [ ] Commit `wrangler.toml` to git (only contains public variables)

---

## Step 3: Cloudflare Workers Setup

### 3.1 Database Configuration

- [ ] D1 database created (if not already):
  ```bash
  wrangler d1 create your-database-name
  ```
- [ ] Database binding added to `wrangler.toml`:
  ```toml
  [[d1_databases]]
  binding = "HIVE_DB"
  database_name = "your-database-name"
  database_id = "your-database-id"
  ```
- [ ] Database schema created (users table with Paddle fields):
  ```sql
  CREATE TABLE users (
    id TEXT PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    paddle_customer_id TEXT,
    paddle_subscription_id TEXT,
    subscription_status TEXT,
    subscription_plan TEXT,
    credits INTEGER DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
  ```
- [ ] Schema applied:
  ```bash
  wrangler d1 execute your-database-name --file=./schema.sql
  ```

### 3.2 Cloudflare Secrets

- [ ] Set Paddle secrets via CLI:

```bash
# Navigate to project directory
cd /path/to/your/project

# Set API key (choose one pattern)

# Option 1: Single API key
wrangler secret put PADDLE_API_KEY
# Paste your API key when prompted

# Option 2: Separate keys (recommended)
wrangler secret put PADDLE_SANDBOX_API_KEY
# Paste sandbox API key

wrangler secret put PADDLE_PRODUCTION_API_KEY
# Paste production API key

# Set webhook secret (CRITICAL)
wrangler secret put PADDLE_WEBHOOK_SECRET
# Paste webhook secret key
```

- [ ] Verify secrets are set:
  ```bash
  wrangler secret list
  ```
- [ ] Confirm output shows:
  - [ ] `PADDLE_API_KEY` or `PADDLE_PRODUCTION_API_KEY`
  - [ ] `PADDLE_WEBHOOK_SECRET`

---

## Step 4: Code Implementation

### 4.1 Webhook Handler

- [ ] Create webhook API route: `src/app/api/paddle/webhook/route.ts`
- [ ] Implement signature verification using `PADDLE_WEBHOOK_SECRET`
- [ ] Handle webhook events:
  - [ ] `subscription.created` → Update database
  - [ ] `subscription.updated` → Update subscription status
  - [ ] `subscription.canceled` → Handle cancellation
  - [ ] `transaction.completed` → Grant credits/activate subscription
  - [ ] `transaction.payment_failed` → Handle failed payment
- [ ] Return 200 OK within 10 seconds
- [ ] Return 401 Unauthorized for invalid signatures
- [ ] Add comprehensive logging

### 4.2 Checkout Integration

- [ ] Install Paddle.js SDK (if using script tag, verify it loads)
- [ ] Create checkout component (e.g., `src/components/PaddleCheckout.tsx`)
- [ ] Initialize Paddle with:
  - [ ] `NEXT_PUBLIC_PADDLE_VENDOR_ID`
  - [ ] `NEXT_PUBLIC_PADDLE_ENVIRONMENT`
  - [ ] `NEXT_PUBLIC_PADDLE_CLIENT_TOKEN`
- [ ] Implement checkout flow using Price IDs
- [ ] Handle checkout success callback
- [ ] Handle checkout failure callback

### 4.3 Subscription Management

- [ ] Create Paddle API client (e.g., `src/lib/paddle-api.ts`)
- [ ] Implement subscription methods:
  - [ ] `getSubscription(subscriptionId)`
  - [ ] `cancelSubscription(subscriptionId)`
  - [ ] `pauseSubscription(subscriptionId)`
  - [ ] `resumeSubscription(subscriptionId)`
- [ ] Create subscription management UI (portal page)
- [ ] Add "Cancel Subscription" functionality
- [ ] Add "Update Payment Method" functionality

---

## Step 5: Testing

### 5.1 Local Development Testing

- [ ] Start development server: `npm run dev`
- [ ] Verify Paddle.js loads (check browser console)
- [ ] Test Paddle environment detection:
  ```javascript
  console.log(window.Paddle.Environment.get());
  // Should show: { environment: "sandbox" }
  ```
- [ ] Navigate to checkout page
- [ ] Click "Subscribe" button
- [ ] Paddle overlay appears
- [ ] Use Paddle test card:
  - Card Number: 4242 4242 4242 4242
  - Expiry: 12/25 (any future date)
  - CVC: 123 (any 3 digits)
  - ZIP: 10001 (any ZIP)
- [ ] Complete checkout successfully
- [ ] Verify webhook fires (check server logs for `[Paddle Webhook]` messages)
- [ ] Verify database updates (user subscription status changes)
- [ ] Verify email sent (if configured)

### 5.2 Webhook Signature Verification Test

- [ ] Test webhook endpoint rejects invalid signatures:
  ```bash
  curl -X POST http://localhost:3001/api/paddle/webhook \
    -H "Content-Type: application/json" \
    -d '{"event_type":"test","data":{}}'
  ```
- [ ] Expected response: 401 Unauthorized
- [ ] Check server logs for signature verification failure

### 5.3 Validation Script

- [ ] Run configuration validation:
  ```bash
  scripts/validate-paddle-config.sh
  ```
- [ ] Expected output: "✅ All required Paddle variables are set"
- [ ] Fix any missing variables

---

## Step 6: Production Deployment

### 6.1 Pre-Deployment Checklist

**Environment Configuration:**

- [ ] All production environment variables set in `wrangler.toml`
- [ ] All Cloudflare secrets set via `wrangler secret put`
- [ ] Production Paddle products created (separate from sandbox)
- [ ] Production price IDs updated in `wrangler.toml` or code

**Security:**

- [ ] Webhook secret is set and secure
- [ ] API keys are stored in Cloudflare secrets (NOT wrangler.toml)
- [ ] `.env.local` is in `.gitignore`
- [ ] No secrets committed to git

**Code:**

- [ ] Webhook signature verification implemented
- [ ] Error handling comprehensive
- [ ] Logging configured
- [ ] Database migrations run

**Infrastructure:**

- [ ] HTTPS enforced on domain
- [ ] Webhook endpoint publicly accessible
- [ ] Rate limiting configured (Cloudflare Dashboard → Security → WAF)
- [ ] Database backups configured

### 6.2 First Deployment (Sandbox Test)

- [ ] Deploy to production with sandbox environment:
  ```toml
  NEXT_PUBLIC_PADDLE_ENVIRONMENT = "sandbox"
  PADDLE_ENVIRONMENT = "sandbox"
  ```
- [ ] Build: `npm run build`
- [ ] Deploy: `wrangler deploy`
- [ ] Test end-to-end in production with sandbox:
  - [ ] Complete checkout flow
  - [ ] Verify webhook fires
  - [ ] Verify database updates
  - [ ] Verify emails sent
- [ ] Cancel test subscription in Paddle Dashboard

### 6.3 Production Go-Live

- [ ] Switch to production Paddle environment:
  ```toml
  NEXT_PUBLIC_PADDLE_ENVIRONMENT = "production"
  PADDLE_ENVIRONMENT = "production"
  NEXT_PUBLIC_PADDLE_CLIENT_TOKEN = "live_your_token"
  PADDLE_WEBHOOK_ID = "ntfset_your_production_webhook_id"
  ```
- [ ] Update Cloudflare secrets to production values:
  ```bash
  wrangler secret put PADDLE_PRODUCTION_API_KEY
  wrangler secret put PADDLE_WEBHOOK_SECRET  # Production webhook secret
  ```
- [ ] Deploy: `wrangler deploy`
- [ ] Update Paddle webhook URL to production domain:
  - [ ] Paddle Dashboard → Developer Tools → Notifications
  - [ ] Update URL to: `https://yourdomain.com/api/paddle/webhook`
  - [ ] Click "Save"
- [ ] Send test webhook from Paddle Dashboard
- [ ] Verify test webhook succeeds (200 OK in Paddle Event logs)

### 6.4 Post-Deployment Verification

- [ ] Test checkout page loads: `curl -I https://yourdomain.com/checkout/basic`
- [ ] Test webhook endpoint security:
  ```bash
  curl -X POST https://yourdomain.com/api/paddle/webhook -d '{"test":"data"}'
  ```
- [ ] Expected: 401 Unauthorized
- [ ] Check Cloudflare logs: `wrangler tail`
- [ ] Check Paddle Event logs: Dashboard → Developer Tools → Events
- [ ] Verify all webhooks are being delivered successfully

---

## Step 7: Monitoring & Maintenance

### 7.1 Set Up Monitoring

- [ ] Configure Cloudflare Workers Analytics:
  - [ ] Cloudflare Dashboard → Workers & Pages → Your Worker → Analytics
- [ ] Configure Paddle notifications:
  - [ ] Paddle Dashboard → Settings → Notifications
  - [ ] Enable email alerts for failed webhooks
- [ ] Set up error logging:
  - [ ] Integrate with Sentry, LogRocket, or similar (optional)
- [ ] Create health check endpoint:
  - [ ] `/api/health` returns 200 OK
  - [ ] Monitor with uptime service (e.g., UptimeRobot)

### 7.2 Regular Maintenance

**Daily:**

- [ ] Check Paddle Dashboard → Events for webhook failures
- [ ] Check Cloudflare logs for errors: `wrangler tail | grep -i error`

**Weekly:**

- [ ] Review subscription metrics (Paddle Dashboard → Reports)
- [ ] Check for failed payments (Dashboard → Transactions)
- [ ] Verify database backups are working

**Monthly:**

- [ ] Review and rotate API keys (security best practice)
- [ ] Audit webhook event logs
- [ ] Update product pricing if needed
- [ ] Review customer support tickets related to payments

### 7.3 Emergency Procedures

**If webhooks start failing:**

- [ ] Check Cloudflare logs: `wrangler tail | grep -i paddle`
- [ ] Verify webhook secret is still set: `wrangler secret list`
- [ ] Check Paddle Event logs for error details
- [ ] Rollback deployment if needed: `wrangler rollback`

**If checkout breaks:**

- [ ] Disable checkout temporarily:
  ```toml
  NEXT_PUBLIC_ENABLE_CHECKOUT = "false"
  ```
- [ ] Deploy: `wrangler deploy`
- [ ] Investigate issue
- [ ] Fix and redeploy
- [ ] Re-enable checkout

**Rollback procedure:**

```bash
# Rollback to previous deployment
wrangler rollback

# Or deploy specific version
wrangler deploy --version-id <version-id>
```

---

## Step 8: Documentation

### 8.1 Project Documentation

- [ ] Document Paddle integration in README.md:
  - [ ] Link to this checklist
  - [ ] Link to configuration guide
  - [ ] Quick start instructions
- [ ] Document environment variables needed
- [ ] Document webhook events handled
- [ ] Document subscription plans and pricing

### 8.2 Team Onboarding

- [ ] Share Paddle Dashboard access with team (if applicable)
- [ ] Document how to access Cloudflare secrets
- [ ] Create runbook for common issues
- [ ] Document emergency contacts (Paddle support, team leads)

---

## Completion

Congratulations! Your Paddle integration is complete.

**Final Checklist:**

- [ ] Sandbox testing successful
- [ ] Production deployment successful
- [ ] Webhooks delivering successfully
- [ ] Database updates working
- [ ] Monitoring configured
- [ ] Team trained
- [ ] Documentation complete

**Next Steps:**

- Review [Quick Reference Guide](./quick-reference.md) for common tasks
- Review [Troubleshooting Guide](./configuration-guide.md#troubleshooting) for
  issue resolution
- Monitor Paddle Dashboard and Cloudflare logs regularly

**Support:**

- Paddle Documentation: https://developer.paddle.com/
- Paddle Support: support@paddle.com
- Cloudflare Discord: https://discord.gg/cloudflaredev

---

**Checklist Version:** 1.0.0 **Last Updated:** 2025-10-09 **Maintainer:**
paddle-expert agent
