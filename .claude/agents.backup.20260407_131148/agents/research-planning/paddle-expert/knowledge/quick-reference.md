# HiveTechs Paddle Integration - Quick Reference Guide

## 🚀 Common Tasks

### Check Subscription Status

```bash
# Get user's Paddle subscription details
wrangler d1 execute hive-user-db --command \
  "SELECT email, paddle_customer_id, paddle_subscription_id, subscription_plan_id, subscription_status FROM users WHERE email = 'user@example.com'"
```

### Verify Webhook Processing

```bash
# Check recent webhook events
wrangler d1 execute hive-user-db --command \
  "SELECT event_type, status, created_at FROM webhook_events ORDER BY created_at DESC LIMIT 10"

# Real-time webhook logs
wrangler tail --format pretty | grep paddle
```

### Test Checkout Flow

```typescript
// 1. Visit pricing page
https://hivetechs.io/pricing

// 2. Click any plan
// 3. Enter email
// 4. Click "Continue to Checkout"
// 5. Use Paddle test card (sandbox):
//    - Visa: 4242 4242 4242 4242
//    - CVV: 123
//    - Expiry: Any future date

// 6. Check Cloudflare logs
wrangler tail --format pretty | grep "subscription.created"
```

### Add New Subscription Plan

```typescript
// 1. Add to /src/config/plans.ts
{
  id: 'pro',
  name: 'Pro',
  price: 15,
  dailyLimit: 150,
  description: 'For professional use',
  features: [...]
}

// 2. Create product in Paddle Dashboard
// 3. Copy Paddle Price ID
// 4. Add price ID to plan config:
priceId: 'pri_01h1234567890'

// 5. Test normalization
const tier = await normalizePlanId(db, "Pro Plan")
// Should return: 'pro'
```

---

## 🔧 Debugging Commands

### Check Plan Mapping

```typescript
// Test plan normalization
import { normalizePlanId } from '@/lib/subscription-plans';

// Test various product name formats
await normalizePlanId(db, 'Unlimited'); // → 'unlimited'
await normalizePlanId(db, 'Unlimited Plan'); // → 'unlimited'
await normalizePlanId(db, 'Hive Unlimited'); // → 'unlimited'
await normalizePlanId(db, '$30/month'); // → 'unlimited'
await normalizePlanId(db, 'Unknown Plan'); // → 'free' (fallback)
```

### Verify Webhook Signature

```bash
# Test signature verification
SECRET="your_webhook_secret"
PAYLOAD='{"event_type":"test"}'
SIGNATURE=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')

curl -X POST http://localhost:3001/api/paddle/webhook \
  -H "Content-Type: application/json" \
  -H "paddle-signature: ts=$(date +%s);h1=$SIGNATURE" \
  -d "$PAYLOAD"

# Expected: 200 OK (if signature valid)
# Expected: 401 Unauthorized (if signature invalid)
```

### Check Credit Transactions

```bash
# View credit purchase history
wrangler d1 execute hive-user-db --command \
  "SELECT u.email, ct.credits, ct.transaction_type, ct.created_at
   FROM credit_transactions ct
   JOIN users u ON ct.user_id = u.id
   ORDER BY ct.created_at DESC LIMIT 20"
```

---

## 🛠️ Configuration Quick Access

### Secrets Management

```bash
# Set secrets
wrangler secret put PADDLE_PRODUCTION_API_KEY
wrangler secret put PADDLE_SANDBOX_API_KEY
wrangler secret put PADDLE_WEBHOOK_SECRET

# List secrets (doesn't show values)
wrangler secret list

# Update secret
wrangler secret put PADDLE_WEBHOOK_SECRET
```

### Environment Switching

```toml
# For sandbox testing (wrangler.toml)
NEXT_PUBLIC_PADDLE_ENVIRONMENT = "sandbox"
NEXT_PUBLIC_PADDLE_CLIENT_TOKEN = "test_your_sandbox_token"

# For production (wrangler.toml)
NEXT_PUBLIC_PADDLE_ENVIRONMENT = "production"
NEXT_PUBLIC_PADDLE_CLIENT_TOKEN = "live_78f1193c72d118ad70ed5b2c2f2"
```

### Rate Limiting (Cloudflare Dashboard)

```
Path: hivetechs.io > Security > WAF > Rate limiting rules

Rule 1: /api/paddle/webhook → 100 req/min per IP
Rule 2: /api/paddle/success-callback → 30 req/min per IP
Rule 3: /api/auth/signup → 10 req/min per IP
Rule 4: /api/portal/* → 30 req/min per IP
```

---

## 📊 Database Queries

### Users with Active Subscriptions

```sql
SELECT
  email,
  subscription_plan_id,
  subscription_status,
  paddle_subscription_id,
  created_at
FROM users
WHERE paddle_subscription_id IS NOT NULL
  AND subscription_status = 'active'
ORDER BY created_at DESC
```

### Users Who Should Be Paid But Are Free

```sql
-- Potential tier mapping issues
SELECT
  email,
  subscription_plan_id,
  paddle_customer_id,
  paddle_subscription_id,
  created_at
FROM users
WHERE paddle_subscription_id IS NOT NULL  -- Has Paddle subscription
  AND subscription_plan_id = 'free'       -- But marked as free
ORDER BY created_at DESC
```

### Failed Webhooks

```sql
SELECT
  event_type,
  status,
  created_at,
  payload
FROM webhook_events
WHERE status = 'failed'
ORDER BY created_at DESC
LIMIT 10
```

### Credit Balances

```sql
SELECT
  email,
  credits_balance,
  subscription_plan_id
FROM users
WHERE credits_balance > 0
ORDER BY credits_balance DESC
```

---

## 🔐 Security Checklist

### Pre-Production Security Review

- [ ] **Secrets Set**: All 5 Cloudflare secrets configured
- [ ] **Signature Verification**: Webhook secret matches Paddle Dashboard
- [ ] **Rate Limiting**: 4 WAF rules active and tested
- [ ] **HTTPS Only**: All endpoints use HTTPS
- [ ] **Input Validation**: Email validation in checkout
- [ ] **SQL Injection**: All queries use prepared statements
- [ ] **Error Messages**: No sensitive data leaked in errors
- [ ] **Webhook Idempotency**: event_id unique constraint enforced

### Security Testing Commands

```bash
# Test rate limiting
for i in {1..15}; do curl https://hivetechs.io/api/paddle/webhook; done
# Expected: 429 Too Many Requests after 100 requests

# Test invalid signature
curl -X POST https://hivetechs.io/api/paddle/webhook \
  -H "paddle-signature: ts=123;h1=invalid" \
  -d '{"event_type":"test"}'
# Expected: 401 Unauthorized

# Test missing signature
curl -X POST https://hivetechs.io/api/paddle/webhook \
  -d '{"event_type":"test"}'
# Expected: 401 Unauthorized
```

---

## 🎯 Performance Optimization

### Caching Strategy

```typescript
// Cache subscription data in D1 (not yet implemented)
interface CachedSubscription {
  subscription_id: string;
  data: string; // JSON stringified
  cached_at: string;
}

// Only fetch from Paddle if cache > 5 minutes old
async function getSubscriptionCached(subId: string) {
  const cached = await db.getCachedSubscription(subId);
  const cacheAge = Date.now() - new Date(cached?.cached_at || 0).getTime();

  if (cacheAge < 5 * 60 * 1000) {
    return JSON.parse(cached.data);
  }

  const fresh = await paddleAPI.getSubscription(subId);
  await db.cacheSubscription(subId, fresh);
  return fresh;
}
```

### Performance Monitoring

```sql
-- Average webhook processing time (if logging timestamps)
SELECT
  event_type,
  AVG(JULIANDAY(processed_at) - JULIANDAY(created_at)) * 86400 AS avg_seconds
FROM webhook_events
WHERE status = 'processed'
  AND processed_at IS NOT NULL
GROUP BY event_type
```

---

## 🚨 Emergency Procedures

### Webhook Secret Compromised

```bash
# 1. Generate new secret in Paddle Dashboard
# 2. Update Cloudflare immediately
wrangler secret put PADDLE_WEBHOOK_SECRET

# 3. Test with sample webhook
curl -X POST https://hivetechs.io/api/paddle/webhook \
  -H "paddle-signature: ts=$(date +%s);h1=NEW_SIGNATURE" \
  -d '{"event_type":"test"}'

# 4. Monitor logs for unauthorized attempts
wrangler tail --format pretty | grep "signature_mismatch"
```

### Database Corruption Recovery

```bash
# 1. Export all users
wrangler d1 execute hive-user-db --command \
  "SELECT * FROM users" --json > users_backup.json

# 2. Export webhook events
wrangler d1 execute hive-user-db --command \
  "SELECT * FROM webhook_events WHERE status = 'pending'" --json > webhooks_pending.json

# 3. Re-create database if needed
wrangler d1 execute hive-user-db --file=schema.sql

# 4. Restore from backup
# (Implement restore script)
```

### Replay Failed Webhooks

```bash
# 1. Get failed webhook payload
PAYLOAD=$(wrangler d1 execute hive-user-db --command \
  "SELECT payload FROM webhook_events WHERE event_id = 'evt_xxx'" --json | jq -r '.[0].payload')

# 2. Get signature
SIGNATURE=$(wrangler d1 execute hive-user-db --command \
  "SELECT signature FROM webhook_events WHERE event_id = 'evt_xxx'" --json | jq -r '.[0].signature')

# 3. Re-send webhook
curl -X POST https://hivetechs.io/api/paddle/webhook \
  -H "Content-Type: application/json" \
  -H "paddle-signature: $SIGNATURE" \
  -d "$PAYLOAD"

# 4. Verify success
wrangler d1 execute hive-user-db --command \
  "SELECT status FROM webhook_events WHERE event_id = 'evt_xxx'"
```

---

## 📝 Code Snippets

### Cancel Subscription

```typescript
import { PaddleAPI } from '@/lib/paddle-api';

async function cancelUserSubscription(userId: string) {
  const user = await db.getUserById(userId);
  if (!user?.paddle_subscription_id) {
    throw new Error('No active subscription');
  }

  const paddleAPI = new PaddleAPI(env);
  const result = await paddleAPI.cancelSubscriptionAtPeriodEnd(
    user.paddle_subscription_id
  );

  if (result.success) {
    console.log(
      'Subscription will cancel on:',
      result.subscription.current_billing_period.ends_at
    );
  } else {
    console.error('Cancellation failed:', result.error);
  }
}
```

### Add Credits Manually

```typescript
async function addCreditsToUser(
  userId: string,
  credits: number,
  reason: string
) {
  const user = await db.getUserById(userId);
  const newBalance = (user.credits_balance || 0) + credits;

  await db.updateUser(userId, { credits_balance: newBalance });

  await db.d1
    ?.prepare(
      `
    INSERT INTO credit_transactions (
      id, user_id, credits, transaction_type, description, created_at
    ) VALUES (?, ?, ?, ?, ?, ?)
  `
    )
    .bind(
      `txn_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
      userId,
      credits,
      'manual_adjustment',
      reason,
      new Date().toISOString()
    )
    .run();

  console.log(
    `✅ Added ${credits} credits to ${user.email}. New balance: ${newBalance}`
  );
}
```

### Check Subscription in Paddle

```typescript
import { PaddleAPI } from '@/lib/paddle-api';

async function syncUserWithPaddle(userId: string) {
  const user = await db.getUserById(userId);
  if (!user?.paddle_customer_id) {
    throw new Error('No Paddle customer ID');
  }

  const paddleAPI = new PaddleAPI(env);

  // Get all subscriptions for customer
  const result = await paddleAPI.getCustomerSubscriptions(
    user.paddle_customer_id
  );

  if (result.success && result.subscriptions.length > 0) {
    console.log(
      'Paddle subscriptions:',
      result.subscriptions.map((s) => ({
        id: s.id,
        status: s.status,
        plan: s.items[0]?.price?.product?.name,
      }))
    );

    // Find active subscription
    const active = result.subscriptions.find((s) => s.status === 'active');
    if (active && active.id !== user.paddle_subscription_id) {
      console.warn('⚠️ Subscription ID mismatch!');
      console.warn('Database:', user.paddle_subscription_id);
      console.warn('Paddle:', active.id);
    }
  }
}
```

---

## 🎓 Learning Resources

### Internal Docs

- **Architecture**: `/docs/PADDLE_INTEGRATION.md`
- **API Reference**: `/docs/PADDLE_API_REFERENCE.md`
- **Webhook Events**: `/docs/PADDLE_WEBHOOK_EVENTS.md`
- **Full Knowledge Base**:
  `/.claude/agents/research-planning/paddle-expert/knowledge/hivetechs-paddle-integration.md`

### External Resources

- **Paddle Billing Docs**: https://developer.paddle.com/
- **Webhook Reference**: https://developer.paddle.com/webhooks/overview
- **Paddle.js v2**: https://developer.paddle.com/paddlejs/overview
- **Subscription Management**:
  https://developer.paddle.com/api-reference/subscriptions/overview

### Key Paddle Concepts

- **Customer**: Person who pays (stored as `paddle_customer_id`)
- **Subscription**: Recurring payment (stored as `paddle_subscription_id`)
- **Transaction**: Individual payment event
- **Price**: Product pricing tier (Paddle Price ID)
- **Product**: What customer is buying (plan or credit pack)

---

**Last Updated**: 2025-10-09 **Quick Reference Version**: v1.0 **Maintained
By**: HiveTechs Development Team
