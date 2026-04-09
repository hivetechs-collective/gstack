# HiveTechs Paddle Integration - Troubleshooting Guide

## 🔍 Diagnostic Checklist

When investigating Paddle integration issues, run through this checklist:

1. **Check Cloudflare Logs**: `wrangler tail --format pretty | grep paddle`
2. **Verify Secrets**: Ensure all 5 secrets are set correctly
3. **Check Database**: Query users table for Paddle IDs
4. **Review Webhook Events**: Check webhook_events table for failures
5. **Test Paddle API**: Verify API connectivity with simple GET request
6. **Check Environment**: Confirm sandbox vs production settings match

---

## 🚨 Common Issues & Solutions

### Issue 1: User Gets Free Tier After Payment

**Symptoms**:

- User pays for subscription in Paddle
- Portal shows free tier (10 daily limit)
- `subscription_plan_id = 'free'` in database

**Root Causes**:

1. Plan name normalization failed
2. Webhook arrived before success callback
3. Tier downgrade protection triggered incorrectly

**Diagnostic Steps**:

```bash
# 1. Check user's current state
wrangler d1 execute hive-user-db --command \
  "SELECT email, subscription_plan_id, daily_limit, paddle_customer_id, paddle_subscription_id, created_at
   FROM users WHERE email = 'user@example.com'"

# 2. Check webhook events for this user
wrangler d1 execute hive-user-db --command \
  "SELECT event_type, payload, created_at
   FROM webhook_events
   WHERE payload LIKE '%user@example.com%'
   ORDER BY created_at DESC LIMIT 5"

# 3. Extract product name from webhook payload
# Look for: subscription.items[0].price.product.name
```

**Solution**:

**If Product Name Mismatch**:

```typescript
// File: /src/lib/subscription-plans.ts (lines 57-97)

// Check current mappings in normalizePlanId()
// Add new pattern if Paddle product name doesn't match

// Example: Paddle uses "Hive Pro Plan" but we expect "Premium"
export async function normalizePlanId(
  db: Database,
  planName: string
): Promise<string> {
  // ... existing code ...

  // Add custom mapping
  if (normalized.includes('hive pro')) {
    return 'premium';
  }

  // ... rest of code ...
}
```

**If Webhook Timing Issue**:

```typescript
// File: /src/app/api/paddle/webhook/route.ts (lines 237-254)

// Race condition protection should prevent this, but verify:
const timeSinceCreation = now - userCreatedAt;
const fiveMinutesInMs = 5 * 60 * 1000;

// If time is < 5 min, webhook should skip update
// Check logs for: "⚠️ WEBHOOK: Skipping update for recently created user"
```

**Manual Fix** (Last Resort):

```bash
# Update user to correct tier
wrangler d1 execute hive-user-db --command \
  "UPDATE users
   SET subscription_plan_id = 'unlimited',
       daily_limit = 999999
   WHERE email = 'user@example.com'"

# Verify fix
wrangler d1 execute hive-user-db --command \
  "SELECT email, subscription_plan_id, daily_limit FROM users WHERE email = 'user@example.com'"
```

---

### Issue 2: Webhook Signature Verification Fails

**Symptoms**:

- Webhooks return 401 Unauthorized
- Logs show: "webhook_signature_mismatch"
- Paddle retries webhooks repeatedly

**Root Causes**:

1. `PADDLE_WEBHOOK_SECRET` not set
2. Secret doesn't match Paddle Dashboard
3. Using production secret in sandbox (or vice versa)

**Diagnostic Steps**:

```bash
# 1. Check which environment is active
wrangler tail --format pretty | grep "PADDLE_ENVIRONMENT"

# 2. Check webhook logs
wrangler tail --format pretty | grep "signature"

# 3. Verify secret is set (won't show value)
wrangler secret list | grep PADDLE_WEBHOOK_SECRET
```

**Solution**:

```bash
# 1. Get webhook secret from Paddle Dashboard
# Location: Paddle Dashboard > Developer Tools > Notifications > Webhook

# 2. Set secret in Cloudflare
wrangler secret put PADDLE_WEBHOOK_SECRET
# Paste secret when prompted

# 3. For sandbox environment
wrangler secret put PADDLE_WEBHOOK_SECRET --env sandbox

# 4. Test with sample webhook
curl -X POST https://hivetechs.io/api/paddle/webhook \
  -H "Content-Type: application/json" \
  -H "paddle-signature: ts=$(date +%s);h1=VALID_SIGNATURE" \
  -d '{"event_type":"subscription.created","data":{}}'

# Expected: 200 OK (if signature valid)
```

**Verify Fix**:

```bash
# Monitor next webhook
wrangler tail --format pretty | grep "Webhook signature verified successfully"
```

---

### Issue 3: Credits Not Added After Purchase

**Symptoms**:

- User buys credit pack
- Payment successful in Paddle
- `credits_balance` unchanged in database

**Root Causes**:

1. Product name doesn't include "credit" or "conversation"
2. `transaction.completed` webhook not received
3. Credit calculation regex fails

**Diagnostic Steps**:

```bash
# 1. Check user's credit balance
wrangler d1 execute hive-user-db --command \
  "SELECT email, credits_balance FROM users WHERE email = 'user@example.com'"

# 2. Check credit transactions
wrangler d1 execute hive-user-db --command \
  "SELECT ct.credits, ct.transaction_type, ct.created_at
   FROM credit_transactions ct
   JOIN users u ON ct.user_id = u.id
   WHERE u.email = 'user@example.com'
   ORDER BY ct.created_at DESC"

# 3. Check transaction.completed webhook
wrangler d1 execute hive-user-db --command \
  "SELECT payload FROM webhook_events
   WHERE event_type = 'transaction.completed'
   ORDER BY created_at DESC LIMIT 1"
```

**Solution**:

**If Product Name Issue**:

```typescript
// File: /src/app/api/paddle/webhook/route.ts (lines 495-498)

// Verify detection logic
const isCreditsTransaction = transaction.items?.some(
  (item) =>
    item.price?.product?.name?.toLowerCase().includes('credit') ||
    item.price?.product?.name?.toLowerCase().includes('conversation')
);

// If Paddle uses different name (e.g., "25 Chats"), add pattern:
item.price?.product?.name?.toLowerCase().includes('chat');
```

**If Calculation Issue**:

```typescript
// File: /src/app/api/paddle/webhook/route.ts (lines 580-593)

function calculateCreditsFromTransaction(transaction: any): number {
  for (const item of transaction.items || []) {
    const productName = item.price?.product?.name?.toLowerCase() || '';
    if (
      productName.includes('credit') ||
      productName.includes('conversation')
    ) {
      // Extract number - current regex: /(\d+)/
      const match = productName.match(/(\d+)/);
      if (match) {
        console.log('Extracted credits:', match[1]); // Debug log
        return parseInt(match[1], 10);
      }
    }
  }
  console.log('⚠️ No credits extracted from product name');
  return 0;
}
```

**Manual Fix**:

```bash
# Add credits manually
wrangler d1 execute hive-user-db --command \
  "UPDATE users SET credits_balance = credits_balance + 25 WHERE email = 'user@example.com'"

# Log transaction
wrangler d1 execute hive-user-db --command \
  "INSERT INTO credit_transactions (id, user_id, credits, transaction_type, description, created_at)
   SELECT 'txn_manual_' || hex(randomblob(4)), id, 25, 'manual_adjustment', 'Manual credit addition', datetime('now')
   FROM users WHERE email = 'user@example.com'"
```

---

### Issue 4: Paddle Checkout Doesn't Open

**Symptoms**:

- Click "Start Trial" button
- Nothing happens (no checkout overlay)
- No JavaScript errors in console

**Root Causes**:

1. Paddle.js failed to load
2. Price ID not set in configuration
3. `NEXT_PUBLIC_USE_PADDLE` disabled
4. JavaScript error during initialization

**Diagnostic Steps**:

```javascript
// 1. Open browser console (F12)
// 2. Check for errors
console.log('Paddle loaded:', typeof window.Paddle); // Should be "object"

// 3. Check environment variables
console.log('Paddle enabled:', process.env.NEXT_PUBLIC_USE_PADDLE);
console.log('Price ID:', priceId); // Should be set
console.log('Environment:', process.env.NEXT_PUBLIC_PADDLE_ENVIRONMENT);

// 4. Check Paddle initialization
console.log('Paddle ready:', paddleReady); // Should be true
```

**Solution**:

**If Paddle.js Not Loaded**:

```typescript
// File: /src/components/CustomCheckout.tsx (lines 98-209)

// Check script loading
const script = document.createElement('script');
script.src = 'https://cdn.paddle.com/paddle/v2/paddle.js';
script.onload = () => {
  console.log('✅ Paddle.js loaded'); // Should see this
};
script.onerror = () => {
  console.error('❌ Failed to load Paddle.js'); // Check network tab
};
```

**If Price ID Missing**:

```typescript
// File: /src/config/plans.ts

// Verify plan has priceId
export const PLANS = [
  {
    id: 'unlimited',
    name: 'Unlimited',
    price: 30,
    priceId: 'pri_01h1234567890', // ← Must be set!
    // ...
  },
];
```

**If Environment Variable Issue**:

```bash
# Check .env.local
NEXT_PUBLIC_USE_PADDLE=true
NEXT_PUBLIC_PADDLE_ENVIRONMENT=sandbox  # or production
NEXT_PUBLIC_PADDLE_CLIENT_TOKEN=live_78f1193c72d118ad70ed5b2c2f2
```

---

### Issue 5: Duplicate Subscriptions Created

**Symptoms**:

- User has multiple subscriptions for same plan
- Multiple charges in Paddle
- Confusing portal experience

**Root Causes**:

1. Email pre-collection disabled
2. User uses different email in Paddle checkout
3. User clicks checkout multiple times quickly

**Prevention**:

```typescript
// File: /src/components/CustomCheckout.tsx (lines 407-460)

// Email pre-collection MUST be enabled
if (showEmailForm) {
  // Collect email first
  // Check for existing subscription
  await checkSubscriptionStatus(customerEmail);
}

// Prefill checkout with email
checkoutConfig.customer = {
  email: customerEmail, // Links Paddle customer to database user
};
```

**Solution**:

```bash
# 1. Identify duplicate subscriptions
wrangler d1 execute hive-user-db --command \
  "SELECT paddle_customer_id, COUNT(*) as count
   FROM users
   WHERE paddle_customer_id IS NOT NULL
   GROUP BY paddle_customer_id
   HAVING COUNT(*) > 1"

# 2. Cancel duplicate in Paddle Dashboard
# Location: Paddle Dashboard > Subscriptions > Find duplicate > Cancel

# 3. Merge users in database (advanced)
# Keep user with most recent activity, update IDs
```

---

### Issue 6: Webhook Not Received

**Symptoms**:

- Payment successful in Paddle
- No webhook events in database
- User not created or updated

**Root Causes**:

1. Webhook URL incorrect in Paddle
2. Webhook disabled in Paddle Dashboard
3. Cloudflare Workers down (rare)
4. Firewall blocking Paddle IPs

**Diagnostic Steps**:

```bash
# 1. Check webhook configuration in Paddle
# Location: Paddle Dashboard > Developer Tools > Notifications

# Expected URL: https://hivetechs.io/api/paddle/webhook
# Expected Events: subscription.*, transaction.*

# 2. Check Cloudflare Workers status
wrangler tail --format pretty

# 3. Manually trigger test webhook from Paddle Dashboard
# Location: Notifications > Test Webhook

# 4. Check webhook events table
wrangler d1 execute hive-user-db --command \
  "SELECT event_type, created_at FROM webhook_events ORDER BY created_at DESC LIMIT 10"
```

**Solution**:

```bash
# 1. Verify webhook URL in Paddle
# Must be: https://hivetechs.io/api/paddle/webhook

# 2. Enable all events in Paddle Dashboard:
#    - subscription.created
#    - subscription.activated
#    - subscription.updated
#    - subscription.canceled
#    - transaction.completed
#    - transaction.paid
#    - transaction.payment_failed

# 3. Set webhook secret in both Paddle and Cloudflare
# Paddle: Copy secret from Notifications page
# Cloudflare: wrangler secret put PADDLE_WEBHOOK_SECRET

# 4. Test with manual webhook
curl -X POST https://hivetechs.io/api/paddle/webhook \
  -H "Content-Type: application/json" \
  -H "paddle-signature: ts=$(date +%s);h1=SIGNATURE" \
  -d '{"event_type":"subscription.created","data":{"id":"sub_test"}}'

# Expected: 200 OK
```

---

### Issue 7: User Can't Access Portal After Payment

**Symptoms**:

- Payment successful
- No portal access email received
- License key not generated

**Root Causes**:

1. SMTP2GO API key invalid
2. Email sending failed in success callback
3. License key generation failed

**Diagnostic Steps**:

```bash
# 1. Check user has license key
wrangler d1 execute hive-user-db --command \
  "SELECT email, license_key FROM users WHERE email = 'user@example.com'"

# 2. Check success callback logs
wrangler tail --format pretty | grep "Portal access email"

# 3. Check SMTP2GO dashboard
# Location: https://www.smtp2go.com/
# Check: Recent emails, failures, bounces
```

**Solution**:

**If License Key Missing**:

```bash
# Generate license key manually
import { generateLicenseKey } from '@/lib/database'
const licenseKey = generateLicenseKey()

wrangler d1 execute hive-user-db --command \
  "UPDATE users SET license_key = '$licenseKey' WHERE email = 'user@example.com'"
```

**If Email Failed**:

```typescript
// File: /src/app/api/paddle/success-callback/route.ts (lines 175-193)

// Check email sending logic
const magicLinkAuth = new MagicLinkAuth(env);
const result = await magicLinkAuth.sendMagicLink(
  user.license_key,
  request.ip || 'success-callback',
  request.headers.get('user-agent') || 'paddle-success'
);

if (!result.success) {
  console.error('❌ Failed to send portal access email:', result.error);
  // Check error details
}
```

**Manual Email Trigger**:

```bash
# Use portal recovery endpoint
curl -X POST https://hivetechs.io/api/portal/auth/recover-key \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com"}'

# User will receive portal access link
```

---

## 🛠️ Advanced Debugging

### Enable Detailed Logging

```typescript
// File: /src/app/api/paddle/webhook/route.ts

// Add at top of handleSubscriptionCreated (line 191)
console.log('🔍 FULL EVENT DATA:', JSON.stringify(event, null, 2));

// Add before tier mapping (line 268)
console.log(
  '🔍 RAW PRODUCT NAME:',
  subscription.items?.[0]?.price?.product?.name
);
console.log('🔍 ALL SUBSCRIPTION DATA:', JSON.stringify(subscription, null, 2));

// Add after tier mapping (line 276)
console.log('🔍 MAPPED TIER:', mappedTier);
console.log('🔍 SHOULD UPDATE:', shouldUpdateTier);
console.log('🔍 USER CURRENT STATE:', {
  plan: user.subscription_plan_id,
  limit: user.daily_limit,
  created: user.created_at,
});
```

### Database Consistency Check

```sql
-- Users with Paddle IDs but no subscription
SELECT email, paddle_customer_id, paddle_subscription_id, subscription_plan_id
FROM users
WHERE paddle_customer_id IS NOT NULL
  AND paddle_subscription_id IS NULL;

-- Users with subscription ID but free tier
SELECT email, paddle_subscription_id, subscription_plan_id, subscription_status
FROM users
WHERE paddle_subscription_id IS NOT NULL
  AND subscription_plan_id = 'free'
  AND subscription_status = 'active';

-- Webhook events that failed
SELECT event_type, status, created_at,
       substr(payload, 1, 200) as payload_preview
FROM webhook_events
WHERE status = 'failed'
ORDER BY created_at DESC
LIMIT 10;

-- Credit transactions with no corresponding purchase webhook
SELECT ct.id, u.email, ct.credits, ct.paddle_transaction_id, ct.created_at
FROM credit_transactions ct
JOIN users u ON ct.user_id = u.id
WHERE ct.transaction_type = 'purchase'
  AND ct.paddle_transaction_id NOT IN (
    SELECT json_extract(payload, '$.data.id')
    FROM webhook_events
    WHERE event_type = 'transaction.completed'
  );
```

---

## 📊 Monitoring & Alerts

### Key Metrics to Monitor

```sql
-- Daily subscription creations
SELECT DATE(created_at) as date, COUNT(*) as new_subscriptions
FROM users
WHERE paddle_subscription_id IS NOT NULL
GROUP BY DATE(created_at)
ORDER BY date DESC
LIMIT 30;

-- Failed webhooks today
SELECT event_type, COUNT(*) as failures
FROM webhook_events
WHERE status = 'failed'
  AND DATE(created_at) = DATE('now')
GROUP BY event_type;

-- Users stuck in pending/past_due
SELECT COUNT(*) as stuck_users
FROM users
WHERE subscription_status IN ('pending', 'past_due')
  AND created_at < datetime('now', '-1 day');

-- Credit purchase rate
SELECT COUNT(*) as credit_purchases, SUM(credits) as total_credits
FROM credit_transactions
WHERE transaction_type = 'purchase'
  AND created_at > datetime('now', '-7 days');
```

### Alert Thresholds

```
⚠️ WARNINGS:
- Webhook failures > 5 per hour
- Failed payments > 10 per day
- Users with missing Paddle IDs > 2% of total
- Signature verification failures > 3 per hour

🚨 CRITICAL:
- All webhooks failing
- Database connection errors
- SMTP2GO API down
- Paddle API returning 5xx errors
- Rate limit exceeded on critical endpoints
```

---

## 🔄 Recovery Procedures

### Replay Failed Webhooks (Batch)

```bash
#!/bin/bash
# File: scripts/replay-failed-webhooks.sh

# Get all failed webhook event IDs
EVENT_IDS=$(wrangler d1 execute hive-user-db --command \
  "SELECT event_id FROM webhook_events WHERE status = 'failed'" --json | jq -r '.[].event_id')

for EVENT_ID in $EVENT_IDS; do
  echo "Replaying webhook: $EVENT_ID"

  # Get payload and signature
  PAYLOAD=$(wrangler d1 execute hive-user-db --command \
    "SELECT payload FROM webhook_events WHERE event_id = '$EVENT_ID'" --json | jq -r '.[0].payload')

  SIGNATURE=$(wrangler d1 execute hive-user-db --command \
    "SELECT signature FROM webhook_events WHERE event_id = '$EVENT_ID'" --json | jq -r '.[0].signature')

  # Re-send webhook
  curl -X POST https://hivetechs.io/api/paddle/webhook \
    -H "Content-Type: application/json" \
    -H "paddle-signature: $SIGNATURE" \
    -d "$PAYLOAD"

  echo "Webhook $EVENT_ID replayed"
  sleep 1  # Rate limiting
done
```

### Sync Users with Paddle (Full Reconciliation)

```typescript
// File: scripts/sync-users-with-paddle.ts

import { PaddleAPI } from '@/lib/paddle-api';

async function syncAllUsers() {
  // Get all users with Paddle customer IDs
  const users = await db.d1
    ?.prepare(
      `
    SELECT id, email, paddle_customer_id, paddle_subscription_id
    FROM users
    WHERE paddle_customer_id IS NOT NULL
  `
    )
    .all();

  const paddleAPI = new PaddleAPI(env);

  for (const user of users.results) {
    try {
      // Get subscriptions from Paddle
      const result = await paddleAPI.getCustomerSubscriptions(
        user.paddle_customer_id
      );

      if (result.success && result.subscriptions.length > 0) {
        const active = result.subscriptions.find((s) => s.status === 'active');

        if (active) {
          // Check for mismatches
          if (active.id !== user.paddle_subscription_id) {
            console.warn(`Mismatch for ${user.email}:`);
            console.warn(`  DB: ${user.paddle_subscription_id}`);
            console.warn(`  Paddle: ${active.id}`);

            // Update database
            await db.updateUser(user.id, {
              paddle_subscription_id: active.id,
            });
          }
        }
      }

      // Rate limiting
      await new Promise((resolve) => setTimeout(resolve, 100));
    } catch (error) {
      console.error(`Failed to sync ${user.email}:`, error);
    }
  }

  console.log('✅ Sync complete');
}
```

---

**Last Updated**: 2025-10-09 **Troubleshooting Guide Version**: v1.0
**Maintained By**: HiveTechs Development Team
