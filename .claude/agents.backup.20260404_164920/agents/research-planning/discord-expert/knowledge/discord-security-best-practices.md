# Discord Security Best Practices

Complete security procedures for Discord webhook integration including webhook
rotation, secret management, privacy compliance, rate limiting, and monitoring.

## 📋 Table of Contents

1. [Webhook URL Security](#webhook-url-security)
2. [Webhook Rotation Procedures](#webhook-rotation-procedures-5-steps)
3. [Environment Variable Configuration](#environment-variable-configuration)
4. [Cloudflare Secrets Management](#cloudflare-secrets-management)
5. [Privacy Guidelines (GDPR Compliance)](#privacy-guidelines-gdpr-compliance)
6. [Rate Limiting Strategies](#rate-limiting-strategies)
7. [Monitoring and Alerts](#monitoring-and-alerts)
8. [Security Checklist](#security-checklist)

---

## Webhook URL Security

### Understanding Webhook Security Model

**Discord webhook security model**: Possession of the webhook URL = permission
to post.

**No signature verification**: Unlike other webhooks (Stripe, GitHub), Discord
webhooks don't have signature verification.

- Whoever has the URL can send messages
- URLs act as bearer tokens
- No way to verify sender identity
- No IP whitelisting available

**Security implications**:

- ✅ Treat webhook URLs like passwords
- ✅ Store in environment variables, not code
- ✅ Never commit to version control
- ✅ Rotate regularly (every 6 months minimum)
- ✅ Rotate immediately if exposed

### Current Security Issue (HiveTechs)

**Location**: `/src/lib/discord-webhook.ts:10` **Issue**: Hardcoded fallback
webhook URL exposed in code **Webhook ID**: `1390445582585303100` **Risk**:
Anyone with repository access can send messages to this webhook

**Exposed Code**:

```typescript
// Line 10
general: process.env.DISCORD_GENERAL_WEBHOOK_URL || 'https://discord.com/api/webhooks/1390445582585303100/xTHMHxulFk4e5YoIOmR_pRi0qdhOp5mMHhkbVYjZEYSt1AGW98sHTss2jCN9j7MmMbM4',
```

**Impact**:

- Public repository: 🔴 CRITICAL - Anyone can find and use webhook
- Private repository: 🟡 MODERATE - Internal team can access
- Git history: ⚠️ URL permanently in history (even if removed now)

**Required Action**: Immediate webhook rotation (see procedures below).

---

## Webhook Rotation Procedures (5 Steps)

### When to Rotate Webhooks

**Immediate rotation required**:

- Webhook URL committed to git (public or private)
- Webhook URL shared in Slack, email, documentation
- Webhook URL found in logs or error messages
- Suspicion of unauthorized access
- Employee with webhook access leaves company

**Scheduled rotation**:

- Every 6 months (recommended)
- After security audit
- When updating security procedures

### Step 1: Identify Exposure

**Check git history**:

```bash
# Search all commits for Discord webhook URLs
git log -S "discord.com/api/webhooks" --all --oneline

# Search current codebase
rg "discord.com/api/webhooks" --type ts
```

**Check documentation**:

- README files
- Wiki pages
- Internal documentation
- Slack messages
- Email threads
- Issue trackers

**Check logs**:

```bash
# Development logs
cat .next/server-logs.txt | grep discord.com

# Production logs (Cloudflare Workers)
wrangler tail | grep discord.com
```

### Step 2: Delete Old Webhook (Discord)

**Via Discord Desktop**:

1. Open Discord server
2. Click server name → Server Settings
3. Navigate to "Integrations" → "Webhooks"
4. Find webhook by ID (from URL):
   - URL: `https://discord.com/api/webhooks/1390445582585303100/...`
   - ID: `1390445582585303100`
5. Click webhook → Scroll down → "Delete Webhook"
6. Confirm deletion

**Via Discord API** (if webhook already deleted in UI):

```bash
# Get webhook ID from URL
WEBHOOK_ID="1390445582585303100"

# Delete via API (requires bot token)
curl -X DELETE "https://discord.com/api/webhooks/${WEBHOOK_ID}" \
  -H "Authorization: Bot YOUR_BOT_TOKEN"
```

**Verification**: Old webhook should return 404:

```bash
curl -X POST "https://discord.com/api/webhooks/1390445582585303100/..." \
  -H "Content-Type: application/json" \
  -d '{"content": "test"}'

# Expected: 404 Not Found
```

### Step 3: Create New Webhook

**Via Discord Desktop**:

1. Go to Server Settings → Integrations → Webhooks
2. Click "New Webhook"
3. Configure webhook:
   - **Name**: "HiveTechs General" (or appropriate name)
   - **Channel**: Select target channel (e.g., #general)
   - **Avatar**: Upload logo (optional)
4. Click "Copy Webhook URL"
5. **IMPORTANT**: Do NOT share this URL yet

**New URL format**:

```
https://discord.com/api/webhooks/{new_id}/{new_token}
```

**Test new webhook**:

```bash
# Test with curl (DO NOT log this command!)
curl -X POST "https://discord.com/api/webhooks/NEW_ID/NEW_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "Test Bot",
    "content": "Testing new webhook (DELETE THIS MESSAGE)"
  }'

# Expected: 204 No Content
# Check Discord - message should appear
```

### Step 4: Update Configuration

**Development environment** (`.env.local`):

```bash
# Open .env.local in secure editor (not shared screen)
nano .env.local

# Update webhook URL
DISCORD_GENERAL_WEBHOOK_URL=https://discord.com/api/webhooks/NEW_ID/NEW_TOKEN

# Save and close
```

**Production environment** (Cloudflare Workers):

```bash
# Set new secret
wrangler secret put DISCORD_GENERAL_WEBHOOK_URL
# Paste: https://discord.com/api/webhooks/NEW_ID/NEW_TOKEN

# Verify secret set
wrangler secret list
# Should show: DISCORD_GENERAL_WEBHOOK_URL (secret set)
```

**Remove hardcoded URLs** (CRITICAL):

```bash
# Find hardcoded webhooks
rg "https://discord.com/api/webhooks" --type ts

# Edit file
code src/lib/discord-webhook.ts

# Remove fallback URL (line 10)
# BEFORE:
general: process.env.DISCORD_GENERAL_WEBHOOK_URL || 'https://discord.com/...',

# AFTER:
general: process.env.DISCORD_GENERAL_WEBHOOK_URL,
```

**Commit changes**:

```bash
git add src/lib/discord-webhook.ts
git commit -m "security: remove hardcoded Discord webhook URL

- Remove fallback webhook URL from line 10
- Require DISCORD_GENERAL_WEBHOOK_URL environment variable
- Part of webhook rotation after exposure

Security incident: Webhook URL exposed in repository
Rotated: 2025-10-12
Old webhook ID: 1390445582585303100 (deleted)
New webhook ID: [redacted]"

git push origin main
```

### Step 5: Test and Verify

**Test development environment**:

```bash
# Start local server
npm run dev

# Test webhook
curl -X GET http://localhost:3000/api/discord/test

# Expected: {"success":true,"message":"Discord webhook test successful!"}
# Check Discord: Should see test messages
```

**Test production environment**:

```bash
# Deploy to Cloudflare Workers
wrangler deploy

# Test production webhook
curl -X GET https://hivetechs.io/api/discord/test

# Expected: {"success":true}
# Check Discord: Should see test messages
```

**Verify old webhook blocked**:

```bash
# Try using old webhook URL (should fail)
curl -X POST "https://discord.com/api/webhooks/OLD_ID/OLD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"content": "test"}'

# Expected: 404 Not Found (webhook deleted)
```

**Integration test** (complete signup flow):

```bash
# Test user signup with Discord notification
curl -X POST http://localhost:3000/api/auth/signup \
  -H "Content-Type: application/json" \
  -d '{
    "email": "test@example.com",
    "name": "Test User"
  }'

# Expected: Success response
# Check Discord #general: "New Member Joined!" message
# Check Discord #admin-logs: Admin log with email
```

---

## Environment Variable Configuration

### Development Configuration

**File**: `.env.local` (root directory) **Security**: Add to `.gitignore`
(verify not committed)

**Template**:

```bash
# ============================================
# Discord Webhook URLs
# ============================================
# PUBLIC CHANNELS (NO SENSITIVE DATA)
# Community announcements, new member celebrations
DISCORD_GENERAL_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy

# Product updates, feature announcements
DISCORD_ANNOUNCEMENTS_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy

# System uptime, performance alerts
DISCORD_STATUS_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy

# PRIVATE ADMIN CHANNELS (PII ALLOWED)
# User signups with emails, detailed logs
DISCORD_ADMIN_LOGS_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy

# User actions, subscription changes
DISCORD_USER_ACTIVITY_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy

# Analytics, usage statistics, revenue
DISCORD_METRICS_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy
```

**Verification**:

```bash
# Check .gitignore includes .env.local
cat .gitignore | grep ".env.local"

# Verify not committed
git status
# Should NOT show .env.local in tracked files

# If committed (EMERGENCY):
git rm --cached .env.local
git commit -m "security: remove .env.local from git"
git push origin main
# Then rotate ALL webhook URLs immediately!
```

### Production Configuration

**Platform**: Cloudflare Workers **Method**: Wrangler secrets (encrypted at
rest)

**Set secrets**:

```bash
# Public channel webhooks
wrangler secret put DISCORD_GENERAL_WEBHOOK_URL
# Paste URL when prompted, press Enter

wrangler secret put DISCORD_ANNOUNCEMENTS_WEBHOOK_URL
wrangler secret put DISCORD_STATUS_WEBHOOK_URL

# Private admin channel webhooks
wrangler secret put DISCORD_ADMIN_LOGS_WEBHOOK_URL
wrangler secret put DISCORD_USER_ACTIVITY_WEBHOOK_URL
wrangler secret put DISCORD_METRICS_WEBHOOK_URL
```

**List secrets** (verify set):

```bash
wrangler secret list

# Expected output:
# [
#   {
#     "name": "DISCORD_GENERAL_WEBHOOK_URL",
#     "type": "secret_text"
#   },
#   {
#     "name": "DISCORD_ADMIN_LOGS_WEBHOOK_URL",
#     "type": "secret_text"
#   },
#   ...
# ]
```

**Delete secret** (if rotation needed):

```bash
wrangler secret delete DISCORD_GENERAL_WEBHOOK_URL
```

**Access in code** (already implemented):

```typescript
// Cloudflare Workers automatically inject secrets into env
const WEBHOOK_URLS = {
  general: process.env.DISCORD_GENERAL_WEBHOOK_URL,
  // ...
};
```

---

## Cloudflare Secrets Management

### Understanding Cloudflare Secrets

**How secrets work**:

- Encrypted at rest in Cloudflare's infrastructure
- Decrypted at runtime in Worker isolate
- Never logged or exposed in Wrangler output
- Scoped to specific Worker (not global)
- Survive deployments (don't need to re-set)

**Best practices**:

- ✅ Use secrets for ALL sensitive data (API keys, webhook URLs)
- ✅ Set secrets BEFORE first deployment
- ✅ Document which secrets are required
- ✅ Rotate secrets regularly (6 months)
- ✅ Delete unused secrets

### Secret Lifecycle

**1. Development** (Local):

- Use `.env.local` for local development
- Never commit `.env.local` to git
- Share template (`.env.local.example`) without values

**2. Staging** (Optional):

- Create separate Cloudflare Worker for staging
- Set staging secrets: `wrangler secret put --env staging`
- Use different Discord server/webhooks for staging

**3. Production**:

- Set production secrets: `wrangler secret put`
- Verify secrets before deployment
- Test after deployment

### Secret Rotation Strategy

**Automated rotation** (recommended):

```bash
# Create rotation script: scripts/rotate-discord-webhooks.sh
#!/bin/bash

echo "Discord Webhook Rotation Script"
echo "================================"
echo ""

# 1. Generate new webhooks (manual step in Discord UI)
echo "Step 1: Create new webhooks in Discord server"
echo "  - Go to Server Settings > Integrations > Webhooks"
echo "  - Create new webhook for each channel"
echo "  - Copy webhook URLs"
echo ""
read -p "Press Enter when webhooks created..."

# 2. Update development environment
echo "Step 2: Update .env.local with new webhook URLs"
read -p "Press Enter when .env.local updated..."

# 3. Update production secrets
echo "Step 3: Updating Cloudflare secrets..."
echo "Paste new webhook URLs when prompted:"

wrangler secret put DISCORD_GENERAL_WEBHOOK_URL
wrangler secret put DISCORD_ANNOUNCEMENTS_WEBHOOK_URL
wrangler secret put DISCORD_STATUS_WEBHOOK_URL
wrangler secret put DISCORD_ADMIN_LOGS_WEBHOOK_URL
wrangler secret put DISCORD_USER_ACTIVITY_WEBHOOK_URL
wrangler secret put DISCORD_METRICS_WEBHOOK_URL

# 4. Deploy
echo "Step 4: Deploying to Cloudflare Workers..."
wrangler deploy

# 5. Test
echo "Step 5: Testing webhooks..."
curl -X GET https://hivetechs.io/api/discord/test

echo ""
echo "Rotation complete! Verify messages in Discord."
echo "Next rotation due: $(date -d '+6 months' '+%Y-%m-%d')"
```

**Manual rotation checklist**:

- [ ] Create new webhooks in Discord (6 total)
- [ ] Update `.env.local` with new URLs
- [ ] Update Cloudflare secrets with `wrangler secret put`
- [ ] Deploy to production with `wrangler deploy`
- [ ] Test with `curl https://hivetechs.io/api/discord/test`
- [ ] Verify messages appear in Discord channels
- [ ] Delete old webhooks in Discord server
- [ ] Document rotation in security log
- [ ] Schedule next rotation (6 months)

---

## Privacy Guidelines (GDPR Compliance)

### Legal Requirements

**GDPR Article 5**: Personal data must be processed lawfully, fairly, and
transparently.

**Key principles**:

- **Data minimization**: Collect only necessary data
- **Purpose limitation**: Use data only for stated purpose
- **Storage limitation**: Delete data when no longer needed
- **Integrity and confidentiality**: Protect data from unauthorized access

**Discord implications**:

- Public Discord channels are NOT secure storage for PII
- Messages in Discord are retained indefinitely (unless deleted)
- Anyone in server can read public channels
- Admin access to private channels should be limited

### PII Classification

**Personally Identifiable Information (PII)**:

- ✅ Email addresses
- ✅ Full names
- ✅ Physical addresses
- ✅ Phone numbers
- ✅ License keys (can identify user)
- ✅ User IDs (internal identifiers)
- ✅ IP addresses

**Non-PII (Safe for public channels)**:

- ✅ Plan tier (free, premium, etc.)
- ✅ Aggregate statistics (total users, revenue)
- ✅ System status (uptime, performance)
- ✅ Feature announcements
- ✅ Generic celebrations (without names/emails)

### Channel Privacy Matrix

| Channel Type               | PII Allowed | Data Examples                    | Access Level |
| -------------------------- | ----------- | -------------------------------- | ------------ |
| **Public Channels**        | ❌ NO       | Plan tiers, counts, status       | Everyone     |
| `#general`                 | ❌ NO       | "New premium member joined!"     | Everyone     |
| `#announcements`           | ❌ NO       | "Feature: Analytics dashboard"   | Everyone     |
| `#system-status`           | ❌ NO       | "API response time: 45ms"        | Everyone     |
| **Private Admin Channels** | ✅ YES      | Emails, names, user IDs          | Admins only  |
| `#admin-logs`              | ✅ YES      | "user@example.com signed up"     | Admins only  |
| `#user-activity`           | ✅ YES      | "user@example.com upgraded"      | Admins only  |
| `#metrics`                 | ⚠️ CAUTION  | Aggregated data (no individuals) | Admins only  |

### Privacy-Safe Notification Pattern

**Template for new notifications**:

```typescript
// Step 1: Identify PII in notification
const hasPII =
  containsEmail(data) || containsName(data) || containsUserId(data);

// Step 2: If PII exists, split into public and private
if (hasPII) {
  // Public version: Remove all PII
  await sendPublicNotification({
    title: 'New Event',
    description: 'Generic description',
    // NO email, NO name, NO user ID
  });

  // Private version: Include PII
  await sendPrivateNotification({
    title: 'Admin Log: New Event',
    fields: [
      { name: 'Email', value: email },
      { name: 'User ID', value: userId },
    ],
    footer: { text: 'Admin Log - Keep Confidential' },
  });
} else {
  // Safe to send to public channel
  await sendPublicNotification(data);
}
```

### Privacy Audit Checklist

**Quarterly privacy audit**:

- [ ] Review all notification functions for PII
- [ ] Verify NO PII in public channels (check Discord history)
- [ ] Verify private channels have restricted access (Discord roles)
- [ ] Check for PII in error messages, logs
- [ ] Verify `.env.local` not committed (git history)
- [ ] Document any privacy incidents
- [ ] Update privacy policy if notification patterns changed

**Privacy incident response**:

1. **Identify**: Which PII was exposed? Where?
2. **Contain**: Delete exposed messages immediately
3. **Fix**: Split notification function (public/private)
4. **Test**: Verify PII no longer exposed
5. **Notify**: Inform affected users (if legally required)
6. **Document**: Record incident and remediation
7. **Prevent**: Update privacy checklist, training

---

## Rate Limiting Strategies

### Discord Rate Limits

**Per-webhook limits** (documented):

- 30 requests per 60 seconds (0.5 requests/second average)
- Burst allowance: Up to 5 requests instantly
- Reset time: Rolling 60-second window

**Global limits** (undocumented, observed):

- 50 requests per second per application (all webhooks combined)
- Higher burst limits for verified bots (not applicable to webhooks)

**429 Response** (rate limited):

```json
{
  "message": "You are being rate limited.",
  "retry_after": 2.5,
  "global": false
}
```

**Headers**:

```
X-RateLimit-Limit: 30
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1640995200
X-RateLimit-Bucket: webhook:1234567890
```

### Rate Limiter Implementation

**Conservative rate limiter** (25 requests/60 seconds):

**File**: `/src/lib/discord-rate-limiter.ts`

```typescript
class DiscordRateLimiter {
  private queue: Array<() => Promise<void>> = [];
  private processing = false;
  private requestTimes: number[] = [];

  // Conservative limit (5 below Discord's 30)
  private readonly maxRequests = 25;
  private readonly timeWindow = 60000; // 60 seconds

  /**
   * Execute function with rate limiting
   */
  async execute(fn: () => Promise<void>): Promise<void> {
    return new Promise((resolve, reject) => {
      this.queue.push(async () => {
        try {
          await fn();
          resolve();
        } catch (error) {
          reject(error);
        }
      });

      if (!this.processing) {
        this.processQueue();
      }
    });
  }

  private async processQueue(): Promise<void> {
    this.processing = true;

    while (this.queue.length > 0) {
      // Clean old request times outside window
      const now = Date.now();
      this.requestTimes = this.requestTimes.filter(
        (time) => now - time < this.timeWindow
      );

      // Check if at rate limit
      if (this.requestTimes.length >= this.maxRequests) {
        // Calculate wait time
        const oldestRequest = Math.min(...this.requestTimes);
        const waitTime = this.timeWindow - (now - oldestRequest) + 100; // +100ms buffer
        console.log(`Rate limit reached, waiting ${waitTime}ms`);
        await new Promise((resolve) => setTimeout(resolve, waitTime));
        continue;
      }

      // Execute next request
      const fn = this.queue.shift();
      if (fn) {
        this.requestTimes.push(Date.now());
        try {
          await fn();
        } catch (error) {
          console.error('Discord request failed:', error);
        }
      }
    }

    this.processing = false;
  }

  /**
   * Get current rate limit status
   */
  getStatus(): { remaining: number; limit: number; resetIn: number } {
    const now = Date.now();
    this.requestTimes = this.requestTimes.filter(
      (time) => now - time < this.timeWindow
    );

    const remaining = this.maxRequests - this.requestTimes.length;
    const oldestRequest =
      this.requestTimes.length > 0 ? Math.min(...this.requestTimes) : now;

    return {
      remaining,
      limit: this.maxRequests,
      resetIn: Math.max(0, this.timeWindow - (now - oldestRequest)),
    };
  }
}

// Global rate limiter instance
export const discordRateLimiter = new DiscordRateLimiter();
```

**Usage**:

```typescript
import { discordRateLimiter } from '@/lib/discord-rate-limiter';

// Wrap webhook calls with rate limiter
await discordRateLimiter.execute(() => sendDiscordMessage(payload, 'general'));

// Check status
const status = discordRateLimiter.getStatus();
console.log(`Rate limit: ${status.remaining}/${status.limit} remaining`);
```

### Handling 429 Responses

**Exponential backoff strategy**:

```typescript
async function sendDiscordMessageWithRetry(
  payload: DiscordWebhookPayload,
  channel: string,
  maxRetries: number = 3
): Promise<boolean> {
  let retries = 0;

  while (retries <= maxRetries) {
    try {
      const response = await fetch(webhookUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });

      if (response.status === 429) {
        // Rate limited - extract retry_after
        const data = await response.json();
        const retryAfter = data.retry_after || 2; // seconds

        console.warn(`Rate limited, retrying after ${retryAfter}s`);
        await new Promise((resolve) => setTimeout(resolve, retryAfter * 1000));

        retries++;
        continue;
      }

      if (!response.ok) {
        console.error(`Discord webhook failed:`, response.status);
        return false;
      }

      return true;
    } catch (error) {
      console.error(`Discord webhook error:`, error);
      retries++;

      // Exponential backoff
      const backoff = Math.pow(2, retries) * 1000;
      await new Promise((resolve) => setTimeout(resolve, backoff));
    }
  }

  return false;
}
```

---

## Monitoring and Alerts

### Metrics to Track

**Webhook success rate**:

- Total webhook calls
- Successful deliveries
- Failed deliveries (4xx, 5xx)
- Rate limit hits (429)
- Timeouts

**Performance**:

- Average response time
- P95/P99 response times
- Queue depth (if using rate limiter)

**Usage by channel**:

- Calls per channel (general, adminLogs, etc.)
- Peak usage times
- Unusual activity spikes

### Logging Strategy

**Development logs**:

```typescript
console.log('🔔 Discord notification:', {
  channel,
  success,
  responseTime: Date.now() - startTime,
  title: payload.embeds?.[0]?.title,
});
```

**Production logs** (Cloudflare Workers):

```typescript
// Use Cloudflare's logging
console.log(
  JSON.stringify({
    event: 'discord_webhook',
    channel,
    success,
    responseTime,
    timestamp: new Date().toISOString(),
  })
);
```

### Alert Configuration

**Alert thresholds**:

- ⚠️ Warning: >10% failure rate in 5 minutes
- 🚨 Critical: >50% failure rate in 5 minutes
- ⚠️ Warning: >5 rate limit hits in 1 hour
- 🚨 Critical: Webhook returning 404 (deleted)

**Alert destinations**:

- Slack/Discord private channel
- Email to ops team
- PagerDuty for critical alerts

**Example alert** (Cloudflare Workers + Webhook):

```typescript
// In webhook error handler
if (response.status === 404) {
  // Webhook deleted - CRITICAL
  await sendCriticalAlert({
    title: '🚨 Discord Webhook Deleted',
    message: `Webhook for channel ${channel} returned 404. Immediate action required.`,
    channel: 'adminLogs', // Alert to admin channel
  });
}
```

---

## Security Checklist

### Pre-Deployment Checklist

- [ ] **Environment Variables**: All 6 webhook URLs configured
- [ ] **No Hardcoded URLs**: Search codebase for hardcoded webhooks
- [ ] **Gitignore**: `.env.local` in `.gitignore`
- [ ] **Git History**: No webhook URLs in commit history
- [ ] **Cloudflare Secrets**: All secrets set with `wrangler secret put`
- [ ] **Privacy Split**: Public notifications separate from admin logs
- [ ] **Error Handling**: Discord failures don't break user operations
- [ ] **Rate Limiting**: Rate limiter implemented (if >10 notifications/minute)
- [ ] **Testing**: All webhooks tested via `/api/discord/test`

### Post-Deployment Checklist

- [ ] **Functionality**: Test complete signup flow with Discord notifications
- [ ] **Privacy**: Verify NO PII in public channels
- [ ] **Monitoring**: Check logs for webhook errors
- [ ] **Rate Limits**: Verify no 429 responses
- [ ] **Documentation**: Team knows how to rotate webhooks
- [ ] **Incident Response**: Rotation procedure documented and tested

### Quarterly Security Review

- [ ] **Webhook Rotation**: Rotate all webhooks (recommended every 6 months)
- [ ] **Access Audit**: Review who has Discord admin access
- [ ] **Privacy Audit**: Check Discord history for PII leaks
- [ ] **Code Audit**: Search codebase for new hardcoded URLs
- [ ] **Log Review**: Analyze webhook failure patterns
- [ ] **Documentation**: Update security procedures if needed

### Incident Response Plan

**Webhook exposure detected**:

1. ⚠️ **IMMEDIATE**: Delete webhook in Discord settings (5 minutes)
2. 🆕 **CREATE**: Generate new webhook for same channel (2 minutes)
3. 🔧 **UPDATE**: Update `.env.local` and Cloudflare secrets (5 minutes)
4. ✅ **TEST**: Verify new webhook works (2 minutes)
5. 📝 **DOCUMENT**: Record incident in security log (10 minutes)
6. 🔍 **AUDIT**: Search git history for other exposed URLs (30 minutes)

**PII leak in public channel**:

1. ⚠️ **IMMEDIATE**: Delete messages with PII from Discord (2 minutes)
2. 🔧 **FIX**: Split notification function (public/private) (15 minutes)
3. ✅ **TEST**: Verify PII only in private channels (5 minutes)
4. 📝 **NOTIFY**: Inform affected users if legally required (varies)
5. 📚 **DOCUMENT**: Record incident and update privacy procedures (30 minutes)

---

**Last Updated**: 2025-10-12 **Next Review**: 2025-04-12 (6 months) **Webhook
Rotation Due**: 2025-04-12
