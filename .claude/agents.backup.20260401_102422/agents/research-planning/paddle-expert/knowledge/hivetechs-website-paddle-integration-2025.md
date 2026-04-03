# HiveTechs Website Paddle Integration (2025 Complete)

**Last Updated**: 2025-10-11 (Emergency deployment documentation - build-time
variables) **Status**: ✅ Production Deployed (Gated/Beta Mode) **Integration
Version**: 2.1 (Emergency lessons learned + Dual Environment + Credit Packs)

---

## Executive Summary

Complete Paddle.com billing integration for HiveTechs Website (hivetechs.io)
with:

- **3 Subscription Plans**: Pro ($20/mo), Max ($30/mo), Team ($120/mo) with
  7-day trials
- **3 Credit Packs**: 25 ($3), 75 ($7), 200 ($15) one-time purchases
- **Dual Environments**: Sandbox (local:3001) + Production (hivetechs.io)
- **Gating System**: Beta/waitlist mode with production Paddle ready
- **Type-Safe Configuration**: Centralized `paddle-plans.ts` with validation
- **Full Automation**: API-driven product creation, no manual work

## Repository Location

**Primary Repo**: `/Users/veronelazio/Developer/Private/hivetechs-website`

**Key Documentation**:

- Master Guide: `docs/PADDLE_MASTER_INTEGRATION_GUIDE.md` (26,000 lines)
- Sandbox vs Production: `docs/PADDLE_SANDBOX_VS_PRODUCTION.md`
- Lessons Learned: `docs/PADDLE_LESSONS_LEARNED.md`
- API Reference: `docs/PADDLE_API_REFERENCE.md`

## Critical Files Reference

### Configuration (Single Source of Truth)

```
src/config/paddle-plans.ts - 249 lines
├─ PADDLE_PRICE_IDS: Record<Environment, Record<ProductId, string>>
├─ getPaddlePriceId(planId, environment?): string
├─ getCurrentPaddleEnvironment(): 'sandbox' | 'production'
├─ isCreditPack(planId): boolean
├─ isSubscriptionPlan(planId): boolean
├─ getCreditPackDetails(packId): { credits, price }
├─ mapPaddleProductNameToPlanId(name): SubscriptionPlanId | null
└─ validatePaddleConfiguration(environment?): void
```

### Checkout Implementation

```
src/app/checkout/[plan]/page.tsx - Server component
src/app/checkout/[plan]/checkout-client.tsx - Client component
src/components/CustomCheckout.tsx - Credit pack handling
```

### Deployment

```
wrangler.toml - Production config
src/middleware.ts - CSP headers for Paddle iframes
```

### Automation Scripts

```
scripts/create-paddle-products-current-pricing.js - Create all products
scripts/verify-paddle-products.js - Verify configuration
```

## Dual Environment Strategy (Critical Understanding)

**THIS IS INTENTIONAL - NOT A MISTAKE**:

```
LOCAL DEVELOPMENT (localhost:3001)
├─ Paddle: Sandbox environment
├─ API: sandbox-api.paddle.com
├─ Price IDs: pri_sandbox_01...
├─ Payments: Test cards (4242 4242 4242 4242)
└─ Purpose: Testing without real money

PRODUCTION DEPLOYMENT (hivetechs.io)
├─ Paddle: Production environment
├─ API: api.paddle.com
├─ Price IDs: pri_01...
├─ Payments: Real credit cards
└─ Purpose: Real customer transactions
```

**Environment Detection**:

```typescript
// Automatic via NODE_ENV
NODE_ENV=development → Sandbox
NODE_ENV=production → Production

// Or explicit override
PADDLE_ENVIRONMENT=sandbox → Force sandbox
PADDLE_ENVIRONMENT=production → Force production
```

## Product Catalog (Both Environments)

### Subscriptions (7-Day Trials)

#### Pro - $20/month

- **Sandbox**: `pri_01k79y8zjtm2czyaw5dkgx3r1s`
- **Production**: `pri_01k7azmt0rv6de1amj81m74ctp`
- Features: 5 concurrent tools, 50 daily conversations

#### Max - $30/month (Popular)

- **Sandbox**: `pri_01k79y8zv9qcb6mvq3csb23s7c`
- **Production**: `pri_01k7azmtfq123hg96eygpn5t0d`
- Features: 8 concurrent tools, unlimited conversations

#### Team - $120/month

- **Sandbox**: `pri_01k79y904ax8cm5twq7j3mgpp5`
- **Production**: `pri_01k7azmtt35bw97fzp92g8z7vm`
- Features: 5 developers, unlimited everything, 20% savings

### Credit Packs (One-Time Purchase)

#### 25 AI Credits - $3

- **Sandbox**: `pri_01jxvb3ad1sy5xbq2aqbz8kv0e`
- **Production**: `pri_01k7azyt42gz9a9vtjahz3naps`
- Never expire, persist through subscription changes

#### 75 AI Credits - $7

- **Sandbox**: `pri_01jxvb3akst16p2vmfdem1hrqh`
- **Production**: `pri_01k7azytd0hdqrv2xybthgpfjq`
- Best value per credit ($0.093 each)

#### 200 AI Credits - $15

- **Sandbox**: `pri_01jxvb3atj8rgtcasbyv8yz034`
- **Production**: `pri_01k7azytnnrfbzanb5zmz1yqmn`
- Power user option ($0.075 per credit)

## Type-Safe Configuration Patterns

### Core Helpers (From paddle-plans.ts)

**Get Price ID**:

```typescript
// Automatic environment
const priceId = getPaddlePriceId('max');

// Explicit environment
const sandboxId = getPaddlePriceId('pro', 'sandbox');
const prodId = getPaddlePriceId('pro', 'production');

// Credit packs work the same
const creditId = getPaddlePriceId('75');
```

**Type Guards (Replace String Matching)**:

```typescript
// Old pattern (fragile)
if (planId === '25' || planId === '75' || planId === '200') {
  // Credit pack logic
}

// New pattern (type-safe)
if (isCreditPack(planId)) {
  // TypeScript narrows type to CreditPackId
  const { credits, price } = getCreditPackDetails(planId);
}
```

**Product Name Mapping (Webhooks)**:

```typescript
// Webhook sends: "Hive Max"
const planId = mapPaddleProductNameToPlanId('Hive Max');
// Returns: 'max'

// Reverse
const displayName = getPaddleProductName('pro');
// Returns: 'Hive Pro'
```

### Validation

**Startup Validation**:

```typescript
// Check all price IDs configured
try {
  validatePaddleConfiguration();
  console.log('✅ Paddle ready');
} catch (error) {
  console.error('❌ Missing price IDs:', error.message);
  process.exit(1);
}
```

## Gating System Integration

### ⚠️ CRITICAL: Build-Time vs Runtime Variables (Emergency Lesson Learned 2025-10-11)

**CRITICAL DISCOVERY**: Next.js `NEXT_PUBLIC_*` variables are **BAKED AT BUILD
TIME** from `.env.local`, NOT loaded at runtime from wrangler.toml!

**What Happened**:

1. `.env.local` had wrong values (SITE_PHASE=live, ENABLE_CHECKOUT=true)
2. `npm run build` baked these values into JavaScript bundle
3. Deployed to production with wrangler.toml showing beta/false
4. **Result**: Production had gating DISABLED even though wrangler.toml said
   beta
5. Emergency rebuild and redeployment required (Deployment ID:
   fb43c26b-938c-47c0-a550-b0172886577b)

**Deployment Flow**:

```
.env.local values → npm run build → BAKED into JS → wrangler deploy
                                         ↓
                        Values are PERMANENT until rebuilt!
```

**NEVER DO THIS** (Does not work):

```bash
# ❌ WRONG: This has NO EFFECT on NEXT_PUBLIC_* variables!
wrangler secret put NEXT_PUBLIC_SITE_PHASE         # live
wrangler secret put NEXT_PUBLIC_ENABLE_CHECKOUT    # true
wrangler secret put NEXT_PUBLIC_ENABLE_SIGNUP      # true
```

**Current State (Beta/Waitlist)**:

```bash
# ✅ CORRECT: Set in .env.local BEFORE building
# .env.local (build-time configuration)
NEXT_PUBLIC_SITE_PHASE=beta
NEXT_PUBLIC_ENABLE_CHECKOUT=false
NEXT_PUBLIC_ENABLE_SIGNUP=false

# Then build and deploy
npm run build
wrangler deploy
```

**Behavior**:

- `/checkout/*` → Redirect to `/waitlist`
- `/auth/signup` → Redirect to `/waitlist`
- Paddle products exist but inaccessible
- Users join waitlist instead of purchasing

**Go-Live Procedure (CORRECTED)**:

```bash
# 1. ⚠️ CRITICAL: Update .env.local FIRST
echo "NEXT_PUBLIC_SITE_PHASE=live" > .env.local
echo "NEXT_PUBLIC_ENABLE_CHECKOUT=true" >> .env.local
echo "NEXT_PUBLIC_ENABLE_SIGNUP=true" >> .env.local

# 2. REBUILD with new values
rm -rf .next
npm run build

# 3. Deploy new build
wrangler deploy

# 4. Verify
curl -I https://hivetechs.io/checkout/max  # Should return 200, not redirect
```

**Emergency Rollback**:

```bash
# 1. Fix .env.local (build-time config)
echo "NEXT_PUBLIC_SITE_PHASE=beta" > .env.local
echo "NEXT_PUBLIC_ENABLE_CHECKOUT=false" >> .env.local
echo "NEXT_PUBLIC_ENABLE_SIGNUP=false" >> .env.local

# 2. REBUILD with gating enabled
npm run build

# 3. Deploy rollback build
wrangler deploy
```

**Post-Go-Live**:

- Checkout routes work normally
- Real payments begin processing
- Paddle integration fully active

**Documentation References**:

- Full details: `docs/GATING_SYSTEM.md` (v1.1.0+)
- Go-live procedures: `docs/PADDLE_GO_LIVE_PROCEDURES.md` (v2.1.0+)
- Emergency deployment: `docs/EMERGENCY_DEPLOYMENT_2025-10-11.md`

## Critical Technical Decisions

### 1. API-Driven Product Creation

**Decision**: Use Paddle API to create products programmatically

**Rationale**:

- ✅ Full automation (sandbox → production)
- ✅ Version controlled configuration
- ✅ Reproducible across environments
- ✅ Zero manual dashboard work

**Implementation**: `scripts/create-paddle-products-current-pricing.js`

**Proof**: All 6 products created in both environments via API

### 2. Type-Safe Configuration File

**Decision**: Centralize all price IDs in `src/config/paddle-plans.ts`

**Rationale**:

- ✅ TypeScript compile-time validation
- ✅ Single source of truth
- ✅ IDE autocomplete and refactoring
- ✅ Built-in error handling

**Alternative Rejected**: Environment variables (12+ variables, no type safety)

### 3. Dual Environment Strategy

**Decision**: Sandbox local, production deployed

**Rationale**:

- ✅ Never test with real money
- ✅ Instant local testing
- ✅ Separate compliance (test vs real data)
- ✅ Safe debugging

**Alternative Risk**: Single production environment could charge real cards
during testing

### 4. Credit Packs as First-Class Products

**Decision**: Implement credit packs alongside subscriptions

**Rationale**:

- ✅ Revenue diversification
- ✅ User retention after cancellation
- ✅ Flexible usage model
- ✅ Alternative to usage-based billing

**Market Research**: OpenAI and Anthropic successfully use credit models

### 5. Gating System for Safe Launch

**Decision**: Deploy with beta mode, enable later

**Rationale**:

- ✅ Production testing before launch
- ✅ Zero customer-facing risk
- ✅ Go-live when business ready
- ✅ Instant rollback capability

**Result**: Confident launch, zero production incidents

## Critical Issues & Solutions

### Issue 1: Paddle Iframe Blocked by CSP

**Symptoms**: Blank iframe, console error "Refused to frame
'https://cdn.paddle.com'"

**Cause**: Content Security Policy blocking Paddle domains

**Solution** (in `src/middleware.ts`):

```typescript
// Allow Paddle domains in CSP
'frame-src https://cdn.paddle.com https://sandbox-cdn.paddle.com https://buy.paddle.com https://sandbox-buy.paddle.com';

// Remove X-Frame-Options (conflicts with Paddle)
// response.headers.set('X-Frame-Options', 'DENY')  // Commented out
```

**Why**: Modern browsers use CSP `frame-ancestors` instead of X-Frame-Options

### Issue 2: Environment Mismatch

**Symptoms**: 403 Forbidden, "API key environment mismatch"

**Cause**: Using sandbox key with production URL or vice versa

**Solution**:

```typescript
// Automatic environment detection
const env = getCurrentPaddleEnvironment();
// Returns 'production' if NODE_ENV=production, else 'sandbox'

const priceId = getPaddlePriceId(planId, env);
// Uses correct price ID for environment
```

**Prevention**: Never hardcode environment or price IDs

### Issue 3: Credit Pack Showing Trial

**Symptoms**: Credit pack checkout shows "7-day trial"

**Cause**: Credit pack created with `billing_cycle` (treated as subscription)

**Solution**: Ensure credit packs have NO `billing_cycle`:

```typescript
// ✅ Correct: One-time purchase
{
  product_id,
  unit_price: { amount: '300', currency_code: 'USD' }
  // No billing_cycle
  // No trial_period
}
```

**Detection**:

```typescript
if (isCreditPack('25')) {
  // One-time purchase flow
}
```

## Automation Scripts

### Create Products (Both Environments)

```bash
# Sandbox
PADDLE_ENVIRONMENT=sandbox node scripts/create-paddle-products-current-pricing.js

# Production
PADDLE_ENVIRONMENT=production node scripts/create-paddle-products-current-pricing.js
```

**What It Does**:

1. Creates 3 subscription products with trials
2. Creates 3 credit pack products (no trials)
3. Outputs price IDs
4. Auto-updates `src/config/paddle-plans.ts` (sandbox only)

### Verify Products

```bash
node scripts/verify-paddle-products.js
```

**Checks**:

- All products exist in Paddle
- Price IDs match config
- Trial periods correct (7 days for subscriptions, none for credits)
- Prices correct ($20, $30, $120, $3, $7, $15)

## Testing Procedures

### Local Testing (Sandbox)

```bash
# Start dev server
npm run dev

# Navigate to checkout
open http://localhost:3001/pricing

# Test subscription
# Click "Start Free Trial"
# Card: 4242 4242 4242 4242
# Verify: 7-day trial, $0.00 today

# Test credit pack
# Click "Buy 75 Credits"
# Card: 4242 4242 4242 4242
# Verify: Immediate charge $7, no trial
```

### Production Testing (Real Cards)

⚠️ **WARNING**: Production uses real money!

```bash
# Small test purchase
# Use personal card (not customer card)
# Buy $3 credit pack
# Verify:
# - Charge on card
# - Webhook received
# - Credits added
# - Email sent

# Test subscription
# Start Pro trial ($20/month)
# Verify:
# - Trial starts immediately
# - No charge today
# - Trial end date correct
```

## Deployment Configuration

### Cloudflare Workers (wrangler.toml)

```toml
[vars]
# Paddle Configuration
NEXT_PUBLIC_PADDLE_ENVIRONMENT = "production"
PADDLE_ENVIRONMENT = "production"
NEXT_PUBLIC_PADDLE_CLIENT_TOKEN = "live_78f1193c72d118ad70ed5b2c2f2"

# Gating System (Beta Mode)
NEXT_PUBLIC_SITE_PHASE = "beta"
NEXT_PUBLIC_ENABLE_CHECKOUT = "false"
NEXT_PUBLIC_ENABLE_SIGNUP = "false"

# Secrets (set via: wrangler secret put NAME)
# PADDLE_API_KEY
# PADDLE_WEBHOOK_SECRET
```

### Security (middleware.ts)

**Critical for Paddle**:

```typescript
// Content Security Policy
'frame-src https://cdn.paddle.com https://sandbox-cdn.paddle.com';

// X-Frame-Options removed (would block Paddle iframe)
```

## Go-Live Checklist

**1 Week Before**:

- [ ] Verify all products exist in production
- [ ] Verify all secrets set (`wrangler secret list`)
- [ ] Test one small transaction with personal card
- [ ] Monitor webhooks for 24 hours
- [ ] Configure Cloudflare WAF rate limiting

**Launch Day**:

```bash
# 1. Update environment variables
wrangler secret put NEXT_PUBLIC_SITE_PHASE        # live
wrangler secret put NEXT_PUBLIC_ENABLE_CHECKOUT   # true
wrangler secret put NEXT_PUBLIC_ENABLE_SIGNUP     # true

# 2. Deploy
wrangler deploy

# 3. Verify
curl -I https://hivetechs.io/checkout/max  # Should return 200

# 4. Test one real purchase

# 5. Monitor
wrangler tail --format pretty
```

**First Hour**:

- Watch logs: `wrangler tail --format pretty`
- Monitor database: `wrangler d1 execute hive-user-db --command="..."`
- Check Paddle dashboard: https://vendors.paddle.com/transactions
- Watch for: Failed transactions, webhook failures, errors

## Rollback Procedure

```bash
# If issues discovered:

# 1. Disable checkout immediately
wrangler secret put NEXT_PUBLIC_ENABLE_CHECKOUT  # false
wrangler secret put NEXT_PUBLIC_SITE_PHASE       # beta

# 2. Deploy
wrangler deploy

# 3. Verify checkout disabled
curl -I https://hivetechs.io/checkout/max  # Should redirect to /waitlist

# 4. Fix issue in development
npm run dev
# Reproduce and fix

# 5. Test thoroughly in sandbox

# 6. Re-enable (follow Launch Day checklist)
```

## Key Lessons Learned

### 1. ⚠️ CRITICAL: Next.js NEXT*PUBLIC*\* Variables are Build-Time (2025-10-11)

**Discovery**: `NEXT_PUBLIC_*` environment variables are baked into the
JavaScript bundle at BUILD TIME from `.env.local`, NOT loaded at runtime from
wrangler.toml

**Impact**: Emergency deployment required when production was built with wrong
`.env.local` values. wrangler.toml settings were completely ignored.

**Root Cause**:

- `.env.local` had `SITE_PHASE=live`, `ENABLE_CHECKOUT=true`
- `npm run build` baked these values into JS bundle permanently
- wrangler.toml had `beta`/`false` but was ignored for client-side variables
- Production launched with gating disabled

**Solution**: Always verify `.env.local` before building:

```bash
# BEFORE every build
cat .env.local | grep NEXT_PUBLIC

# If wrong, fix THEN rebuild
npm run build
wrangler deploy
```

**Key Takeaway**: wrangler secrets only affect server-side code. Client-side
variables are locked at build time.

**Documentation**: See `docs/GATING_SYSTEM.md` v1.1.0+ for complete explanation

### 2. Paddle API Supports Full Automation

**Discovery**: API v2 supports programmatic product/price creation

**Impact**: Eliminated all manual dashboard work

**Implementation**: `scripts/create-paddle-products-current-pricing.js`

### 3. Amount Must Be in Cents (Strings)

```typescript
// ❌ Wrong: This is $0.20!
"amount": "20"

// ✅ Correct: This is $20.00
"amount": "2000"
```

### 4. Trials Require Billing Cycle

```typescript
// ❌ Fails
{ trial_period: { interval: 'day', frequency: 7 } }

// ✅ Works
{
  billing_cycle: { interval: 'month', frequency: 1 },
  trial_period: { interval: 'day', frequency: 7 }
}
```

### 5. Cache Subscription Data

```typescript
// ❌ Bad: Poll API every request
const sub = await paddle.getSubscription(subId);

// ✅ Good: Cache in DB, update via webhooks
const cached = await db.getCachedSubscription(userId);
if (cached && isCacheFresh(cached, 5 * 60 * 1000)) {
  return cached;
}
```

### 6. Always Verify Webhook Signatures

```typescript
// ❌ Dangerous
const event = await request.json();
await processEvent(event);

// ✅ Secure
const signature = request.headers.get('paddle-signature');
const body = await request.text();
verifySignature(signature, body, secret);
const event = JSON.parse(body);
```

## Monitoring & Maintenance

### Daily Checks

```bash
# Transaction volume
curl -H "Authorization: Bearer $PADDLE_API_KEY" \
  https://api.paddle.com/transactions?from=yesterday

# Failed payments (Paddle dashboard)
# Webhook delivery rate (should be >95%)
# Database health
wrangler d1 execute hive-user-db --command="SELECT subscription_status, COUNT(*) FROM users GROUP BY subscription_status"
```

### Weekly Tasks

- Revenue report (Paddle dashboard)
- Churn analysis (cancellation patterns)
- Trial conversion rate (target: >20%)
- Customer support review
- Update documentation with new issues

### Monthly Tasks

- API key rotation (every 90 days)
- Rate limit review (Cloudflare Analytics)
- Database optimization (`VACUUM`, `ANALYZE`)
- Backup verification
- Security audit

## Quick Reference

### Environment Variables

| Variable                          | Local       | Production   |
| --------------------------------- | ----------- | ------------ |
| `PADDLE_ENVIRONMENT`              | sandbox     | production   |
| `PADDLE_API_KEY`                  | test\_...   | pdl*live*... |
| `NEXT_PUBLIC_PADDLE_CLIENT_TOKEN` | test\_...   | live\_...    |
| `NODE_ENV`                        | development | production   |

### Price IDs

| Product           | Sandbox                        | Production                     |
| ----------------- | ------------------------------ | ------------------------------ |
| Pro ($20/mo)      | pri_01k79y8zjtm2czyaw5dkgx3r1s | pri_01k7azmt0rv6de1amj81m74ctp |
| Max ($30/mo)      | pri_01k79y8zv9qcb6mvq3csb23s7c | pri_01k7azmtfq123hg96eygpn5t0d |
| Team ($120/mo)    | pri_01k79y904ax8cm5twq7j3mgpp5 | pri_01k7azmtt35bw97fzp92g8z7vm |
| 25 Credits ($3)   | pri_01jxvb3ad1sy5xbq2aqbz8kv0e | pri_01k7azyt42gz9a9vtjahz3naps |
| 75 Credits ($7)   | pri_01jxvb3akst16p2vmfdem1hrqh | pri_01k7azytd0hdqrv2xybthgpfjq |
| 200 Credits ($15) | pri_01jxvb3atj8rgtcasbyv8yz034 | pri_01k7azytnnrfbzanb5zmz1yqmn |

### Common Commands

```bash
# Development
npm run dev                     # Start local (sandbox)

# Scripts
node scripts/create-paddle-products-current-pricing.js
node scripts/verify-paddle-products.js

# Deployment
wrangler deploy                 # Deploy to production
wrangler secret put VAR_NAME    # Set secret
wrangler secret list            # List secrets
wrangler tail --format pretty   # Watch logs

# Go-Live
wrangler secret put NEXT_PUBLIC_SITE_PHASE         # live
wrangler secret put NEXT_PUBLIC_ENABLE_CHECKOUT    # true
wrangler secret put NEXT_PUBLIC_ENABLE_SIGNUP      # true
wrangler deploy
```

## Related Documentation

### In hivetechs-website Repository

**Master Documentation**:

- `docs/PADDLE_MASTER_INTEGRATION_GUIDE.md` - Complete reference (26,000 lines)
- `docs/PADDLE_SANDBOX_VS_PRODUCTION.md` - Environment differences
- `docs/PADDLE_LESSONS_LEARNED.md` - Mistakes and solutions

**Product Documentation**:

- `PADDLE_PRODUCTS_CREATED.md` - Sandbox products
- `PADDLE_PRODUCTION_PRODUCTS.md` - Production products

**Technical Documentation**:

- `docs/PADDLE_API_REFERENCE.md` - API endpoints
- `docs/PADDLE_WEBHOOK_EVENTS.md` - Event handling
- `docs/PADDLE_AUTOMATION_SCRIPTS.md` - Script guide

**Deployment Documentation**:

- `docs/PADDLE_PRODUCTION_DEPLOYMENT.md` - Deployment procedures
- `docs/PADDLE_GO_LIVE_CHECKLIST.md` - Launch checklist

### In claude-pattern Repository

**This File**:

- `.claude/agents/research-planning/paddle-expert/knowledge/hivetechs-website-paddle-integration-2025.md`

**Cross-Repository Reference**:

- See: `REPOSITORY_SYNC_MANIFEST.md` for sync strategy

---

**Integration Status**: ✅ Production Ready (Beta/Waitlist Mode) **Last
Updated**: 2025-10-11 (v2.1 - Critical build-time variable documentation) **Next
Review**: After go-live (within 1 week of enabling checkout) **Maintained By**:
HiveTechs Collective LLC **Emergency Deployment**: 2025-10-11 (Gating fix -
Deployment ID: fb43c26b-938c-47c0-a550-b0172886577b)

---

_For questions: support@hivetechs.io_
