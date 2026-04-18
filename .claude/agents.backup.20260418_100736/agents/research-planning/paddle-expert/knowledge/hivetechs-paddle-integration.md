# HiveTechs Paddle Integration - Complete Knowledge Base

## Quick Reference

**Status**: ✅ Production-Ready **Paddle Billing**: v2 **Environment**:
Production + Sandbox **Vendor ID**: 232110 **Webhook ID**:
`ntfset_01jxts5prxmd9y82gh5frmkhhf`

---

## File Locations (Critical Reference)

### Core Integration Files

| File                                            | Lines | Purpose                                | Key Functions                                       |
| ----------------------------------------------- | ----- | -------------------------------------- | --------------------------------------------------- |
| `/src/app/api/paddle/webhook/route.ts`          | 593   | Webhook handler with HMAC verification | POST(), handleSubscription*(), handleTransaction*() |
| `/src/app/api/paddle/success-callback/route.ts` | 440   | Success callback with user creation    | GET(), POST()                                       |
| `/src/components/CustomCheckout.tsx`            | 707   | Paddle.js v2 checkout UI               | CustomCheckout()                                    |
| `/src/lib/paddle-api.ts`                        | 245   | Paddle API client for subscriptions    | PaddleAPI class with 12 methods                     |
| `/src/lib/subscription-plans.ts`                | 118   | Plan normalization system              | normalizePlanId(), getDailyLimitForPlan()           |
| `/src/config/plans.ts`                          | 45    | 6 subscription plans                   | PLANS array                                         |
| `/src/config/credit-packs.ts`                   | 14    | 3 credit packs                         | CREDIT_PACKS array                                  |
| `/src/lib/database.ts`                          | N/A   | D1 database with Paddle fields         | Database interface                                  |
| `wrangler.toml`                                 | 134   | Configuration & secrets                | vars, d1_databases, queues (commented)              |

---

## Configuration Quick Access

### Environment Variables (wrangler.toml lines 13-19)

```toml
ENVIRONMENT = "production"
NEXT_PUBLIC_SITE_URL = "https://hivetechs.io"
NEXT_PUBLIC_PADDLE_ENVIRONMENT = "production"
PADDLE_WEBHOOK_ID = "ntfset_01jxts5prxmd9y82gh5frmkhhf"
NEXT_PUBLIC_PADDLE_CLIENT_TOKEN = "live_78f1193c72d118ad70ed5b2c2f2"
```

### Secrets (Set via wrangler CLI)

```bash
wrangler secret put PADDLE_PRODUCTION_API_KEY
wrangler secret put PADDLE_SANDBOX_API_KEY
wrangler secret put PADDLE_WEBHOOK_SECRET
wrangler secret put SMTP2GO_API_KEY
wrangler secret put JWT_SECRET
```

### Subscription Plans (src/config/plans.ts)

```typescript
export const PLANS = [
  { id: 'free', price: 0, dailyLimit: 10 },
  { id: 'basic', price: 5, dailyLimit: 50 },
  { id: 'standard', price: 10, dailyLimit: 100 },
  { id: 'premium', price: 20, dailyLimit: 200 },
  { id: 'unlimited', price: 30, dailyLimit: 'unlimited' },
  { id: 'team-unlimited', price: 115, dailyLimit: 'unlimited' },
];
```

**⚠️ CRITICAL**: Paddle Price IDs not yet set in plans configuration!

---

## Critical Business Logic Patterns

### 1. User Creation Flow (NEVER create users in webhooks!)

**Success Callback Creates Users FIRST** (success-callback/route.ts lines
76-106):

```typescript
// SUCCESS CALLBACK: Creates user with paid tier
const tier = await normalizePlanId(db, plan); // Maps to paid tier
const newUser = {
  id: uuidv4(),
  email,
  license_key: licenseKey,
  subscription_plan_id: tier, // ✅ Paid tier
  daily_limit: dailyLimit, // ✅ Paid tier limits
  paddle_customer_id: paddleCustomerId,
  paddle_subscription_id: paddleSubscriptionId,
  subscription_status: 'active',
};
await db.createUser(newUser);
```

**Webhook NEVER Creates Users** (webhook/route.ts lines 341-353):

```typescript
// WEBHOOK: Only updates existing users
if (!user) {
  console.log('⚠️ WARNING: User not found for subscription.created webhook');
  console.log('⚠️ User should have been created by success callback first');
  console.log(
    '⚠️ Skipping user creation in webhook to prevent free tier assignment'
  );
  return; // ✅ Exit without creating user
}
```

**Why This Pattern?**

- Prevents race conditions between webhook and success callback
- Ensures users always get paid tier (not free tier)
- Success callback runs first (user clicks checkout → success callback →
  redirect → webhook arrives)

---

### 2. Race Condition Protection (webhook/route.ts lines 237-254)

```typescript
// Check if user was recently created (< 5 minutes ago)
const userCreatedAt = new Date(user.created_at).getTime();
const now = new Date().getTime();
const timeSinceCreation = now - userCreatedAt;
const fiveMinutesInMs = 5 * 60 * 1000;

// If user created < 5 min ago AND already has paid tier, skip webhook update
if (
  timeSinceCreation < fiveMinutesInMs &&
  user.subscription_plan_id !== 'free'
) {
  console.log(
    '⚠️ WEBHOOK: Skipping update for recently created user with paid tier'
  );
  return; // ✅ Exit to prevent overwriting success callback's tier assignment
}
```

**Why This Protection?**

- Webhook may arrive AFTER success callback sets paid tier
- Without this, webhook could overwrite paid tier with incorrect mapping
- 5-minute window ensures success callback has time to complete

---

### 3. Plan Name Normalization (subscription-plans.ts lines 57-97)

**Problem**: Paddle product names don't match internal plan IDs

- Paddle: "Unlimited Plan" or "Hive Unlimited" or "$30/month Plan"
- Internal: "unlimited"

**Solution**: `normalizePlanId()` maps variations to standard IDs

```typescript
export async function normalizePlanId(
  db: Database,
  planName: string
): Promise<string> {
  if (!planName) return 'free';

  const normalized = planName.toLowerCase().trim();

  // 1. Check if already valid plan ID (e.g., "unlimited")
  const validIds = await getValidPlanIds(db);
  if (validIds.includes(normalized)) return normalized;

  // 2. Get all plans from database
  const plans = await getActiveSubscriptionPlans(db);

  // 3. Check exact name matches (e.g., "Unlimited")
  for (const plan of plans) {
    if (plan.name.toLowerCase() === normalized) return plan.id;
  }

  // 4. Check partial matches (e.g., "Hive Unlimited Plan" → "unlimited")
  for (const plan of plans) {
    if (
      normalized.includes(plan.id) ||
      normalized.includes(plan.name.toLowerCase())
    ) {
      return plan.id;
    }
  }

  // 5. Price-based matching (e.g., "$30/month" → "unlimited")
  const priceMatch = normalized.match(/\$?(\d+)/);
  if (priceMatch) {
    const price = parseInt(priceMatch[1]) * 100; // Convert to cents
    const matchingPlan = plans.find((p) => p.price === price);
    if (matchingPlan) return matchingPlan.id;
  }

  // 6. Default to free if no match
  console.warn('⚠️ Unknown plan name:', planName, '- defaulting to free');
  return 'free';
}
```

**Usage in Webhooks** (webhook/route.ts lines 268-276):

```typescript
const productName = subscription.items?.[0]?.price?.product?.name;
const mappedTier = await normalizePlanId(db, productName);

console.log('🚨 WEBHOOK DEBUG - Tier mapping:', {
  raw_product_name: productName,
  mapped_tier: mappedTier,
  daily_limit: await getDailyLimitForPlan(db, mappedTier),
});
```

---

### 4. Prevent Tier Downgrades (webhook/route.ts lines 278-287)

```typescript
// CRITICAL FIX: Only update tier if we successfully mapped it (not free)
// OR if user currently has free tier
const shouldUpdateTier =
  mappedTier !== 'free' || user.subscription_plan_id === 'free';

console.log('🚨 WEBHOOK DEBUG - Update decision:', {
  current_plan: user.subscription_plan_id,
  mapped_tier: mappedTier,
  should_update_tier: shouldUpdateTier,
  reason: shouldUpdateTier
    ? 'Valid tier or upgrading from free'
    : 'Preventing downgrade to free',
});

// Only update tier if shouldUpdateTier is true
if (shouldUpdateTier) {
  updates.subscription_plan_id = mappedTier;
  updates.daily_limit = await getDailyLimitForPlan(db, mappedTier);
}
```

**Why This Logic?**

- If `normalizePlanId()` fails to map product name, it returns 'free'
- Without this check, paid users would be downgraded to free
- Only allow tier update if:
  - Mapped tier is valid (not 'free'), OR
  - User is currently on free tier (legit upgrade)

---

### 5. Credit Pack Detection (webhook/route.ts lines 495-537)

```typescript
// Detect if transaction is for credits vs subscription
const isCreditsTransaction = transaction.items?.some(
  (item) =>
    item.price?.product?.name?.toLowerCase().includes('credit') ||
    item.price?.product?.name?.toLowerCase().includes('conversation')
);

if (isCreditsTransaction) {
  // Extract credits amount from product name
  const creditsAmount = calculateCreditsFromTransaction(transaction);
  const newBalance = (user.credits_balance || 0) + creditsAmount;

  // Update user balance
  await db.updateUser(user.id, { credits_balance: newBalance });

  // Log transaction for audit
  await db.d1
    ?.prepare(
      `
    INSERT INTO credit_transactions (
      id, user_id, credits, transaction_type, paddle_transaction_id,
      created_at, description
    ) VALUES (?, ?, ?, ?, ?, ?, ?)
  `
    )
    .bind(
      `txn_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
      user.id,
      creditsAmount,
      'purchase',
      transaction.id,
      new Date().toISOString(),
      `Purchased ${creditsAmount} conversation credits`
    )
    .run();
}
```

**Credit Calculation** (webhook/route.ts lines 580-593):

```typescript
function calculateCreditsFromTransaction(transaction: any): number {
  for (const item of transaction.items || []) {
    const productName = item.price?.product?.name?.toLowerCase() || '';
    if (
      productName.includes('credit') ||
      productName.includes('conversation')
    ) {
      // Extract number from product name (e.g., "25 Credits" -> 25)
      const match = productName.match(/(\d+)/);
      if (match) return parseInt(match[1], 10);
    }
  }
  return 0;
}
```

---

## Webhook Signature Verification (CRITICAL SECURITY)

**Implementation** (webhook/route.ts lines 56-81):

```typescript
// 1. Check secret is configured
if (!env.PADDLE_WEBHOOK_SECRET) {
  logger.critical(
    'PADDLE_WEBHOOK_SECRET not configured - webhook verification disabled'
  );
  return NextResponse.json(
    {
      error:
        'Webhook signature verification required but PADDLE_WEBHOOK_SECRET not configured',
    },
    { status: 500 }
  );
}

// 2. Check signature header exists
const signature = headersList.get('paddle-signature');
if (!signature) {
  logSecurityEvent('webhook_missing_signature', request, {
    provider: 'paddle',
  });
  return NextResponse.json(
    {
      error: 'Missing webhook signature - unauthorized request rejected',
    },
    { status: 401 }
  );
}

// 3. Verify HMAC-SHA256 signature
const crypto = await import('crypto');
const hmac = crypto.createHmac('sha256', env.PADDLE_WEBHOOK_SECRET);
hmac.update(body); // Raw request body (NOT parsed JSON!)
const expectedSignature = hmac.digest('hex');

// 4. Extract h1 signature from header
// Header format: "ts=1234567890;h1=abcdef123456..."
const signatureParts = signature.split(';');
const h1Signature = signatureParts
  .find((part) => part.startsWith('h1='))
  ?.substring(3);

// 5. Compare signatures (constant-time)
if (h1Signature !== expectedSignature) {
  logSecurityEvent('webhook_signature_mismatch', request, {
    provider: 'paddle',
    expectedSignature: expectedSignature.substring(0, 16) + '...',
    receivedSignature: h1Signature?.substring(0, 16) + '...',
  });
  return NextResponse.json({ error: 'Invalid signature' }, { status: 401 });
}
```

**Security Benefits**:

- Prevents fake subscription upgrades
- Prevents unauthorized account modifications
- Prevents revenue loss from spoofed transactions
- Ensures webhook authenticity

---

## Paddle.js v2 Checkout Implementation

**File**: `/src/components/CustomCheckout.tsx` (707 lines)

### Email Pre-Collection (lines 407-460)

```typescript
// Show email form FIRST before checkout
if (showEmailForm) {
  return (
    <form onSubmit={handleEmailSubmit}>
      <input
        type="email"
        value={customerEmail}
        onChange={(e) => setCustomerEmail(e.target.value)}
      />
      <Button type="submit">Continue to Checkout</Button>
    </form>
  )
}
```

**Why Pre-Collect Email?**

- Check for existing subscriptions (prevent duplicates)
- Prefill Paddle checkout with email (links Paddle customer to database user)
- Skip subscription check for credit purchases (anyone can buy credits)

### Paddle.js Initialization (lines 98-216)

```typescript
// STEP 1: Load Paddle.js SDK
const script = document.createElement('script');
script.src = 'https://cdn.paddle.com/paddle/v2/paddle.js';

script.onload = () => {
  // STEP 2: Set environment FIRST (critical for sandbox)
  if (process.env.NEXT_PUBLIC_PADDLE_ENVIRONMENT === 'sandbox') {
    window.Paddle!.Environment.set('sandbox');
  }

  // STEP 3: Initialize with client token
  window.Paddle!.Initialize({
    token: process.env.NEXT_PUBLIC_PADDLE_CLIENT_TOKEN!,
    eventCallback: (event) => {
      // STEP 4: Handle checkout.completed event
      if (event.name === 'checkout.completed') {
        // Extract Paddle IDs
        const customer = event.data?.customer;
        const subscription = event.data?.subscription;
        const transaction = event.data?.transaction;

        // Determine callback URL
        const isCredits = plan.includes('Credits');
        const callbackUrl = isCredits
          ? '/api/paddle/credits-callback'
          : '/api/paddle/success-callback';

        // Send transaction data to backend
        fetch(callbackUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            email: customer?.email || customerEmail,
            plan: plan,
            paddleCustomerId: customer?.id,
            paddleSubscriptionId: subscription?.id,
            transactionData: event.data,
          }),
        });

        // Update UI
        setPaymentCompleted(true);
      }
    },
  });

  setPaddleReady(true);
};
```

### Opening Checkout (lines 274-315)

```typescript
const handleCheckout = () => {
  const checkoutConfig = {
    items: [
      {
        priceId: priceId, // Paddle Price ID from configuration
        quantity: 1,
      },
    ],
    customer: {
      email: customerEmail, // Pre-collected email
    },
    settings: {
      displayMode: 'overlay',
      theme: 'dark',
      // NOTE: No successUrl → enables JavaScript event flow
    },
  };

  window.Paddle!.Checkout.open(checkoutConfig);
};
```

**Why No Success URL?**

- Success URL prevents JavaScript events from firing
- We NEED `checkout.completed` event to capture Paddle customer/subscription IDs
- Without IDs, we can't link Paddle data to database user

---

## Database Schema (Paddle Fields)

**Users Table**:

```sql
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  license_key TEXT UNIQUE,
  subscription_plan_id TEXT DEFAULT 'free',
  daily_limit INTEGER DEFAULT 10,
  credits_balance INTEGER DEFAULT 0,

  -- Paddle Integration Fields
  paddle_customer_id TEXT UNIQUE,           -- Links user to Paddle customer
  paddle_subscription_id TEXT,              -- Current active subscription ID
  subscription_status TEXT,                 -- active, canceled, past_due, paused
  subscription_end_date TEXT,               -- ISO 8601 date string

  account_status TEXT DEFAULT 'active',
  created_at TEXT NOT NULL,
  updated_at TEXT
)
```

**Webhook Events Table**:

```sql
CREATE TABLE webhook_events (
  event_id TEXT PRIMARY KEY,                -- Unique constraint = idempotency
  event_type TEXT NOT NULL,
  payload TEXT NOT NULL,                    -- Full JSON payload
  signature TEXT,                           -- HMAC signature
  status TEXT DEFAULT 'pending',
  created_at TEXT NOT NULL,
  processed_at TEXT
)
```

**Credit Transactions Table**:

```sql
CREATE TABLE credit_transactions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  credits INTEGER NOT NULL,                 -- Positive = purchase, negative = usage
  transaction_type TEXT NOT NULL,           -- purchase, usage, refund
  paddle_transaction_id TEXT,
  description TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id)
)
```

---

## Common Troubleshooting Scenarios

### Issue: User Gets Free Tier After Payment

**Debug** (webhook/route.ts lines 198-276):

```typescript
console.log('🔍 CRITICAL: Paddle subscription details:', {
  subscription_id: subscription.id,
  customer_id: customerId,
  customer_email: customerEmail,
  items: subscription.items?.map((item) => ({
    product_name: item.price?.product?.name, // ← Check this!
  })),
});

console.log('🚨 WEBHOOK DEBUG - Tier mapping:', {
  raw_product_name: productName, // ← What Paddle sent
  mapped_tier: mappedTier, // ← What we mapped it to
  daily_limit: await getDailyLimitForPlan(db, mappedTier),
});
```

**Solution**:

1. Check Paddle product names match `normalizePlanId()` patterns
2. Add new patterns to `normalizePlanId()` if needed
3. Verify tier isn't being downgraded due to `shouldUpdateTier` logic

### Issue: Webhook Signature Fails

**Debug** (webhook/route.ts lines 69-75):

```typescript
if (h1Signature !== expectedSignature) {
  logSecurityEvent('webhook_signature_mismatch', request, {
    provider: 'paddle',
    expectedSignature: expectedSignature.substring(0, 16) + '...',
    receivedSignature: h1Signature?.substring(0, 16) + '...',
  });
}
```

**Solution**:

```bash
# Check environment
echo $NEXT_PUBLIC_PADDLE_ENVIRONMENT

# Update secret for correct environment
wrangler secret put PADDLE_WEBHOOK_SECRET                # Production
wrangler secret put PADDLE_WEBHOOK_SECRET --env sandbox  # Sandbox
```

### Issue: Credits Not Added

**Debug** (webhook/route.ts lines 495-537):

```typescript
const isCreditsTransaction = transaction.items?.some(
  (item) =>
    item.price?.product?.name?.toLowerCase().includes('credit') ||
    item.price?.product?.name?.toLowerCase().includes('conversation')
);

if (isCreditsTransaction) {
  const creditsAmount = calculateCreditsFromTransaction(transaction);
  console.log('✅ Credits added:', creditsAmount, 'New balance:', newBalance);
}
```

**Solution**:

1. Verify product name includes "credit" or "conversation"
2. Check `calculateCreditsFromTransaction()` regex extracts number correctly
3. Verify `transaction.completed` webhook is being received

---

## Deployment Checklist

### Pre-Deployment

- [ ] Set all Cloudflare secrets (5 required)
- [ ] Configure Paddle webhook URL and secret
- [ ] Set Paddle Price IDs in plans configuration ⚠️ **NOT YET DONE**
- [ ] Test sandbox mode thoroughly
- [ ] Configure rate limiting in Cloudflare WAF (4 rules)
- [ ] Verify SMTP2GO email delivery

### Post-Deployment Verification

```bash
# Check webhook endpoint accessible
curl https://hivetechs.io/api/paddle/webhook

# Check Cloudflare logs
wrangler tail --format pretty | grep paddle

# Verify database schema
wrangler d1 execute hive-user-db --command \
  "SELECT name FROM sqlite_master WHERE type='table'"

# Test subscription flow in sandbox
# (Use Paddle test cards)
```

---

## Agent Quick Commands

**When asked about Paddle integration**:

- Reference this file first for HiveTechs-specific patterns
- Check `/docs/PADDLE_INTEGRATION.md` for architecture overview
- Check `/docs/PADDLE_API_REFERENCE.md` for API details
- Check `/docs/PADDLE_WEBHOOK_EVENTS.md` for webhook specifics

**When debugging tier issues**:

- Check `normalizePlanId()` mapping logic (subscription-plans.ts lines 57-97)
- Verify `shouldUpdateTier` logic (webhook/route.ts lines 278-287)
- Check race condition protection (webhook/route.ts lines 237-254)

**When adding new plans**:

1. Add to `/src/config/plans.ts`
2. Create product in Paddle Dashboard
3. Copy Paddle Price ID to plans configuration
4. Test `normalizePlanId()` with new product name
5. Deploy and verify in sandbox

---

**Last Updated**: 2025-10-09 **Integration Version**: v1.0 (Production-Ready,
Price IDs pending) **Maintained By**: HiveTechs Development Team
