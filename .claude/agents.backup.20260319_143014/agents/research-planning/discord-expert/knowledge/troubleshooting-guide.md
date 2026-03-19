# Discord Integration Troubleshooting Guide

Comprehensive troubleshooting guide for Discord webhook integration issues
including common errors, diagnostic procedures, solutions, and recovery steps.

## 📋 Table of Contents

1. [Issue 1: Webhook URL Exposed in Code](#issue-1-webhook-url-exposed-in-code)
2. [Issue 2: Webhook Failures (404/401/403)](#issue-2-webhook-failures-404401403)
3. [Issue 3: Rate Limiting (429 Errors)](#issue-3-rate-limiting-429-errors)
4. [Issue 4: Privacy Leak (PII in Public Channels)](#issue-4-privacy-leak-pii-in-public-channels)
5. [Issue 5: Environment Variables Not Loading](#issue-5-environment-variables-not-loading)
6. [Issue 6: Cloudflare Workers Secret Issues](#issue-6-cloudflare-workers-secret-issues)
7. [Issue 7: Messages Not Appearing](#issue-7-messages-not-appearing)
8. [Issue 8: Signup Flow Not Triggering Discord](#issue-8-signup-flow-not-triggering-discord)
9. [Diagnostic Commands Reference](#diagnostic-commands-reference)
10. [Emergency Recovery Procedures](#emergency-recovery-procedures)

---

## Issue 1: Webhook URL Exposed in Code

### Symptoms

- Webhook URL found in git repository (public or private)
- Webhook URL in commit history (`git log -S "discord.com/api/webhooks"`)
- Hardcoded webhook URL in source code
- **Current Issue**: Line 10 of `/src/lib/discord-webhook.ts` has exposed URL

### Example Error

```typescript
// src/lib/discord-webhook.ts:10
general: process.env.DISCORD_GENERAL_WEBHOOK_URL || 'https://discord.com/api/webhooks/1390445582585303100/xTHMHxulFk4e5YoIOmR_pRi0qdhOp5mMHhkbVYjZEYSt1AGW98sHTss2jCN9j7MmMbM4',
```

**Risk**: Anyone with repository access can send messages to Discord channel.

### Diagnosis Steps

1. **Search codebase for hardcoded URLs**:

   ```bash
   rg "discord.com/api/webhooks" --type ts
   # Output: src/lib/discord-webhook.ts:10
   ```

2. **Check git history**:

   ```bash
   git log -S "discord.com/api/webhooks" --all --oneline
   # Shows all commits with webhook URLs
   ```

3. **Check if webhook still works** (indicates not yet rotated):
   ```bash
   curl -X POST "https://discord.com/api/webhooks/1390445582585303100/..." \
     -H "Content-Type: application/json" \
     -d '{"content":"test"}'
   # If 204: Still works (needs rotation)
   # If 404: Already deleted
   ```

### Solution: Immediate Webhook Rotation

**Step 1: Delete exposed webhook (5 minutes)**:

1. Open Discord → Server Settings → Integrations → Webhooks
2. Find webhook by ID: `1390445582585303100`
3. Click webhook → Delete Webhook → Confirm

**Step 2: Create new webhook (2 minutes)**:

1. Same channel (#general)
2. Click "New Webhook"
3. Name: "HiveTechs General"
4. Copy new webhook URL

**Step 3: Update configuration (5 minutes)**:

```bash
# Development
nano .env.local
# Update: DISCORD_GENERAL_WEBHOOK_URL=https://discord.com/api/webhooks/NEW_ID/NEW_TOKEN

# Production
wrangler secret put DISCORD_GENERAL_WEBHOOK_URL
# Paste: https://discord.com/api/webhooks/NEW_ID/NEW_TOKEN
```

**Step 4: Remove hardcoded URL (5 minutes)**:

```typescript
// BEFORE (line 10):
general: process.env.DISCORD_GENERAL_WEBHOOK_URL || 'https://discord.com/...',

// AFTER:
general: process.env.DISCORD_GENERAL_WEBHOOK_URL,
```

**Step 5: Commit, deploy, test (5 minutes)**:

```bash
git add src/lib/discord-webhook.ts
git commit -m "security: remove hardcoded Discord webhook URL"
wrangler deploy
curl -X GET https://hivetechs.io/api/discord/test
```

### Prevention

- Never commit webhook URLs to git
- Always use environment variables
- Add `.env.local` to `.gitignore`
- Rotate webhooks every 6 months
- Review code for hardcoded secrets before deployment

---

## Issue 2: Webhook Failures (404/401/403)

### Symptoms

- Discord API returns 404 Not Found
- Discord API returns 401 Unauthorized
- Discord API returns 403 Forbidden
- Test endpoint fails: `{"success":false}`
- Logs: `Discord webhook failed for general: 404`

### Common Error Messages

**404 Not Found**:

```json
{
  "message": "Unknown Webhook",
  "code": 10015
}
```

**Cause**: Webhook deleted or URL incorrect.

**401 Unauthorized**:

```json
{
  "message": "Invalid Webhook Token",
  "code": 50027
}
```

**Cause**: Webhook token invalid or expired.

**403 Forbidden**:

```json
{
  "message": "Cannot send messages to this channel",
  "code": 50013
}
```

**Cause**: Webhook lacks permissions or channel deleted.

### Diagnosis Steps

1. **Test webhook URL directly**:

   ```bash
   curl -X POST "$DISCORD_GENERAL_WEBHOOK_URL" \
     -H "Content-Type: application/json" \
     -d '{"content":"test"}' \
     -v
   # Check response status and body
   ```

2. **Verify webhook exists in Discord**:
   - Go to Server Settings → Integrations → Webhooks
   - Look for webhook by name or ID
   - If not listed: Webhook was deleted

3. **Check webhook URL format**:

   ```bash
   echo $DISCORD_GENERAL_WEBHOOK_URL
   # Should match: https://discord.com/api/webhooks/{id}/{token}
   # Common issues:
   #   - Missing token (only ID)
   #   - Extra whitespace
   #   - HTTP instead of HTTPS
   ```

4. **Verify channel permissions**:
   - Webhook's channel still exists
   - Webhook has permission to send messages
   - Channel not archived or read-only

### Solutions

**For 404 (Webhook deleted)**:

1. Create new webhook in Discord
2. Update environment variables
3. Redeploy application
4. Test again

**For 401 (Invalid token)**:

1. Verify webhook URL copied correctly (entire URL, including token)
2. Check for extra characters (spaces, newlines)
3. Recreate webhook if token corrupted
4. Update configuration

**For 403 (Permission denied)**:

1. Check channel permissions
2. Verify webhook not disabled
3. Recreate webhook with proper permissions
4. Update configuration

### Quick Fix Script

```bash
#!/bin/bash
# scripts/fix-discord-webhook.sh

echo "Discord Webhook Troubleshooting Script"
echo "======================================"
echo ""

# Test webhook
echo "Testing webhook: $DISCORD_GENERAL_WEBHOOK_URL"
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$DISCORD_GENERAL_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{"content":"test"}')

if [ "$RESPONSE" = "204" ]; then
  echo "✅ Webhook working!"
elif [ "$RESPONSE" = "404" ]; then
  echo "❌ 404: Webhook deleted - recreate in Discord"
elif [ "$RESPONSE" = "401" ]; then
  echo "❌ 401: Invalid token - check webhook URL"
elif [ "$RESPONSE" = "403" ]; then
  echo "❌ 403: Permission denied - check channel permissions"
else
  echo "❌ Unknown error: HTTP $RESPONSE"
fi
```

---

## Issue 3: Rate Limiting (429 Errors)

### Symptoms

- Discord API returns 429 Too Many Requests
- Logs: `Rate limited, retrying after 2.5s`
- Messages delayed or not sent
- Burst of notifications failing

### Error Response

```json
{
  "message": "You are being rate limited.",
  "retry_after": 2.5,
  "global": false
}
```

### Discord Rate Limits

- **Per webhook**: 30 requests per 60 seconds (0.5 req/sec average)
- **Burst allowance**: Up to 5 requests instantly
- **Global limit**: 50 requests per second (all webhooks combined)

### Diagnosis Steps

1. **Check logs for 429 responses**:

   ```bash
   # Development
   cat .next/server-logs.txt | grep "429"

   # Production (Cloudflare Workers)
   wrangler tail | grep "429"
   ```

2. **Count notifications in timeframe**:

   ```bash
   # Count Discord calls in last minute
   cat logs.txt | grep "Discord webhook" | tail -60 | wc -l
   # If >30: Rate limit likely
   ```

3. **Identify notification sources**:
   ```bash
   # Find which notifications triggering rate limit
   rg "sendDiscordMessage" --type ts
   # Check for loops, bulk operations
   ```

### Solutions

**Immediate mitigation**:

1. Wait for rate limit to reset (check `retry_after` seconds)
2. Reduce notification frequency
3. Batch notifications (combine multiple into one embed)

**Implement rate limiter** (recommended):

```typescript
// lib/discord-rate-limiter.ts
class DiscordRateLimiter {
  private queue: Array<() => Promise<void>> = [];
  private processing = false;
  private requestTimes: number[] = [];
  private readonly maxRequests = 25; // Conservative (Discord allows 30)
  private readonly timeWindow = 60000; // 60 seconds

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
      const now = Date.now();
      this.requestTimes = this.requestTimes.filter(
        (time) => now - time < this.timeWindow
      );

      if (this.requestTimes.length >= this.maxRequests) {
        const oldestRequest = Math.min(...this.requestTimes);
        const waitTime = this.timeWindow - (now - oldestRequest) + 100;
        console.log(`Rate limit reached, waiting ${waitTime}ms`);
        await new Promise((resolve) => setTimeout(resolve, waitTime));
        continue;
      }

      const fn = this.queue.shift();
      if (fn) {
        this.requestTimes.push(Date.now());
        await fn();
      }
    }

    this.processing = false;
  }
}

export const discordRateLimiter = new DiscordRateLimiter();
```

**Usage**:

```typescript
// Wrap all Discord calls
await discordRateLimiter.execute(() => sendDiscordMessage(payload, 'general'));
```

**Implement retry with exponential backoff**:

```typescript
async function sendDiscordMessageWithRetry(
  payload: DiscordWebhookPayload,
  channel: string,
  maxRetries: number = 3
): Promise<boolean> {
  let retries = 0;

  while (retries <= maxRetries) {
    const response = await fetch(webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    if (response.status === 429) {
      const data = await response.json();
      const retryAfter = data.retry_after || 2;

      console.warn(`Rate limited, retrying after ${retryAfter}s`);
      await new Promise((resolve) => setTimeout(resolve, retryAfter * 1000));
      retries++;
      continue;
    }

    return response.ok;
  }

  return false;
}
```

### Prevention

- Implement rate limiter proactively
- Batch notifications (combine multiple events into single message)
- Reduce notification frequency (daily summaries instead of real-time)
- Use different webhooks for high-volume channels

---

## Issue 4: Privacy Leak (PII in Public Channels)

### Symptoms

- Emails appearing in #general (public channel)
- User names in #announcements
- License keys or user IDs in #system-status
- Privacy compliance violation

### Example Privacy Leak

**Current code** (BEFORE privacy fix commit `d277df9`):

```typescript
// ❌ WRONG: Sends email to public channel
await sendDiscordMessage(
  {
    embeds: [
      {
        title: 'New User Signup',
        fields: [
          { name: 'Email', value: 'user@example.com' }, // 🚨 PII exposed!
          { name: 'Plan', value: 'Premium' },
        ],
      },
    ],
  },
  'general'
); // Public channel!
```

**After privacy fix** (commit `d277df9`):

```typescript
// ✅ CORRECT: Split public and private
// Public: No PII
await notifyNewUserPublic('premium');

// Private: With PII
await notifyNewUserPrivate('user@example.com', 'John Doe', 'premium');
```

### Diagnosis Steps

1. **Audit public channels**:
   - Manually review #general, #announcements, #system-status
   - Search for email pattern: `Ctrl+F` → `@`
   - Search for license key pattern: `HIVE-`
   - Search for user IDs: `user_`, `usr_`

2. **Check notification functions**:

   ```bash
   # Find all Discord notifications
   rg "sendDiscordMessage" --type ts

   # Check which channels used
   rg "sendDiscordMessage.*'general'" --type ts
   ```

3. **Review function parameters**:
   ```typescript
   // Check what data passed to public notifications
   // Search for:
   rg "notifyNewUserPublic.*email" --type ts
   // Should return NO results (email shouldn't be in public function)
   ```

### Solution: Split Notifications

**Step 1: Identify PII**:

- Email addresses
- Full names
- License keys
- User IDs
- Any identifiable information

**Step 2: Create separate functions**:

```typescript
// Public version (NO PII)
export async function notifyNewUserPublic(plan: string): Promise<boolean> {
  const embed: DiscordEmbed = {
    title: '🎉 New Member Joined!',
    description: `Welcome to our newest ${plan} tier member!`,
    fields: [
      { name: 'Plan', value: plan },
      // NO email, NO name, NO user ID
    ],
  };

  return sendDiscordMessage({ embeds: [embed] }, 'general');
}

// Private version (PII allowed)
export async function notifyNewUserPrivate(
  email: string,
  name: string,
  plan: string
): Promise<boolean> {
  const embed: DiscordEmbed = {
    title: '🆕 New User Registration',
    fields: [
      { name: 'Email', value: email },
      { name: 'Name', value: name },
      { name: 'Plan', value: plan },
    ],
    footer: { text: 'Admin Log - Keep Confidential' },
  };

  if (!WEBHOOK_URLS.adminLogs) {
    console.warn('No admin logs webhook - skipping private notification');
    return false;
  }

  return sendDiscordMessage({ embeds: [embed] }, 'adminLogs');
}

// Combined function
export async function notifyNewUser(
  email: string,
  name: string,
  plan: string
): Promise<boolean> {
  await notifyNewUserPublic(plan); // Public celebration
  await notifyNewUserPrivate(email, name, plan); // Admin log
  return true;
}
```

**Step 3: Update all call sites**:

```bash
# Find all calls to old function
rg "notifyNewUser\(" --type ts

# Update to use split functions or combined function
```

**Step 4: Delete exposed messages**:

1. Go to Discord public channels
2. Find messages with PII
3. Right-click → Delete Message
4. Document in privacy incident log

**Step 5: Test privacy**:

```bash
# Test signup
curl -X POST http://localhost:3000/api/auth/signup \
  -H "Content-Type: application/json" \
  -d '{"email":"privacy-test@example.com","name":"Privacy Test"}'

# Verify:
# - #general: Should NOT contain email
# - #admin-logs: Should contain email
```

### Privacy Audit Checklist

- [ ] Review #general for emails, names, user IDs
- [ ] Review #announcements for user data
- [ ] Review #system-status for PII
- [ ] Verify all notification functions split correctly
- [ ] Test signup flow (check both channels)
- [ ] Document privacy patterns in code comments
- [ ] Update privacy policy if needed

### GDPR Compliance Notes

**Legal requirements**:

- Data minimization: Collect only necessary PII
- Purpose limitation: Use PII only for stated purpose
- Storage limitation: Delete PII when no longer needed
- Integrity and confidentiality: Protect PII from unauthorized access

**Discord implications**:

- Public channels are NOT secure storage
- Messages retained indefinitely (unless deleted)
- Anyone in server can read public channels
- Private channels should have restricted access (Discord roles)

---

## Issue 5: Environment Variables Not Loading

### Symptoms

- Logs: `No webhook URL configured for channel: general`
- `process.env.DISCORD_GENERAL_WEBHOOK_URL` is `undefined`
- Works when hardcoded, fails with environment variable
- Different behavior between development and production

### Diagnosis Steps

1. **Check .env.local exists**:

   ```bash
   ls -la .env.local
   # If not found: File missing
   ```

2. **Verify environment variable syntax**:

   ```bash
   cat .env.local | grep DISCORD_GENERAL_WEBHOOK_URL
   # Should show: DISCORD_GENERAL_WEBHOOK_URL=https://...
   ```

3. **Check for common syntax errors**:

   ```bash
   # ❌ Spaces around =
   DISCORD_GENERAL_WEBHOOK_URL = https://...

   # ✅ No spaces
   DISCORD_GENERAL_WEBHOOK_URL=https://...

   # ❌ Quotes (unnecessary in Next.js)
   DISCORD_GENERAL_WEBHOOK_URL="https://..."

   # ✅ No quotes
   DISCORD_GENERAL_WEBHOOK_URL=https://...
   ```

4. **Verify .env.local loaded**:
   ```typescript
   // Add debug log
   console.log('Discord webhook:', process.env.DISCORD_GENERAL_WEBHOOK_URL);
   // Should output: Discord webhook: https://discord.com/api/webhooks/...
   ```

### Solutions

**For missing .env.local**:

```bash
# Create from template
cp .env.local.example .env.local

# Fill in webhook URLs
nano .env.local
```

**For syntax errors**:

```bash
# Fix syntax (remove spaces, quotes)
nano .env.local

# Restart server
npm run dev
```

**For development vs production mismatch**:

```bash
# Development: .env.local
cat .env.local | grep DISCORD

# Production: Cloudflare secrets
wrangler secret list

# Ensure both configured
```

**For Next.js not loading variables**:

```bash
# Verify Next.js version (should be 13+)
npm list next

# Restart dev server
npm run dev
```

---

## Issue 6: Cloudflare Workers Secret Issues

### Symptoms

- Works in development, fails in production
- Production logs: `No webhook URL configured`
- Wrangler shows secrets set
- `wrangler secret list` shows correct secrets

### Diagnosis Steps

1. **Check secrets exist**:

   ```bash
   wrangler secret list
   # Should show all 6 Discord webhooks
   ```

2. **Check deployment logs**:

   ```bash
   wrangler tail
   # Look for: "No webhook URL configured"
   ```

3. **Test secret access**:

   ```typescript
   // Add debug log in worker
   export default {
     async fetch(request, env) {
       console.log('Has Discord webhook:', !!env.DISCORD_GENERAL_WEBHOOK_URL);
       // Should log: Has Discord webhook: true
     },
   };
   ```

4. **Verify wrangler.toml configuration**:

   ```toml
   # Should NOT have webhook URLs here
   [vars]
   # Webhooks should be secrets, not vars

   # Correct: Use secrets
   # Set with: wrangler secret put DISCORD_GENERAL_WEBHOOK_URL
   ```

### Solutions

**For missing secrets**:

```bash
# Set all required secrets
wrangler secret put DISCORD_GENERAL_WEBHOOK_URL
wrangler secret put DISCORD_ANNOUNCEMENTS_WEBHOOK_URL
wrangler secret put DISCORD_STATUS_WEBHOOK_URL
wrangler secret put DISCORD_ADMIN_LOGS_WEBHOOK_URL
wrangler secret put DISCORD_USER_ACTIVITY_WEBHOOK_URL
wrangler secret put DISCORD_METRICS_WEBHOOK_URL
```

**For corrupted secrets**:

```bash
# Delete and recreate
wrangler secret delete DISCORD_GENERAL_WEBHOOK_URL
wrangler secret put DISCORD_GENERAL_WEBHOOK_URL
```

**For environment mismatch**:

```bash
# Check current environment
wrangler whoami

# Verify deploying to correct account
# Set secrets in correct environment
```

**For access issues in code**:

```typescript
// WRONG: Using process.env in Workers
const webhookUrl = process.env.DISCORD_GENERAL_WEBHOOK_URL;

// CORRECT: Using env parameter
export default {
  async fetch(request, env) {
    const webhookUrl = env.DISCORD_GENERAL_WEBHOOK_URL;
    // ...
  },
};
```

**Redeploy after fixing**:

```bash
wrangler deploy
curl -X GET https://hivetechs.io/api/discord/test
```

---

## Issue 7: Messages Not Appearing

### Symptoms

- Webhook returns 204 (success)
- No error in logs
- Messages not visible in Discord
- Test endpoint succeeds but no messages

### Diagnosis Steps

1. **Check Discord channel permissions**:
   - Can you see the channel?
   - Are you logged into correct server?
   - Is channel archived or hidden?

2. **Verify webhook channel**:
   - Go to Server Settings → Integrations → Webhooks
   - Click webhook → Check "Channel" field
   - Verify correct channel selected

3. **Check message filtering**:
   - Discord settings → Text & Images → Show all messages
   - Channel settings → Hide Muted Channels (disabled)

4. **Test with simple message**:
   ```bash
   curl -X POST "$DISCORD_GENERAL_WEBHOOK_URL" \
     -H "Content-Type: application/json" \
     -d '{"content":"Simple test message"}'
   # If this appears: Issue with embed formatting
   # If this doesn't appear: Channel/permissions issue
   ```

### Solutions

**For channel visibility issues**:

1. Check you're in correct Discord server
2. Verify channel not muted or hidden
3. Check role permissions (can you see channel?)

**For webhook channel mismatch**:

1. Recreate webhook for correct channel
2. Update environment variables
3. Test again

**For embed formatting issues**:

```typescript
// Test with simple content first
await sendDiscordMessage(
  {
    content: 'Test message',
  },
  'general'
);

// Then add embed
await sendDiscordMessage(
  {
    content: 'Test message',
    embeds: [
      {
        title: 'Test Embed',
        description: 'Testing embeds',
      },
    ],
  },
  'general'
);
```

---

## Issue 8: Signup Flow Not Triggering Discord

### Symptoms

- User signup succeeds
- No Discord notification sent
- Logs don't show Discord errors
- Direct Discord test works (`/api/discord/test`)

### Diagnosis Steps

1. **Check Discord call in signup handler**:

   ```bash
   rg "notifyNewUser" src/app/api/auth/signup/route.ts
   # Should find call around line 115-125
   ```

2. **Check error handling**:

   ```typescript
   // Verify try-catch around Discord call
   try {
     await notifyNewUser(...)
     console.log('Discord notifications sent')
   } catch (error) {
     console.error('Discord notification failed:', error)
     // This should NOT throw - signup should continue
   }
   ```

3. **Add debug logs**:

   ```typescript
   console.log('Before Discord notification');
   await notifyNewUser(email, name, plan, userId);
   console.log('After Discord notification');
   ```

4. **Test signup flow**:
   ```bash
   curl -X POST http://localhost:3000/api/auth/signup \
     -H "Content-Type: application/json" \
     -d '{"email":"test@example.com","name":"Test User"}' \
     -v
   # Check logs for Discord-related messages
   ```

### Solutions

**For missing Discord call**:

```typescript
// Add Discord notification to signup handler
// src/app/api/auth/signup/route.ts

// After user created
try {
  await notifyNewUser(
    newUser.email,
    newUser.name || 'Anonymous',
    newUser.subscription_plan_id,
    newUser.id
  );
  console.log('🔔 Discord notifications sent');
} catch (discordError) {
  console.error('🔔 Discord notification failed:', discordError);
  // Don't fail signup if Discord fails
}
```

**For silent failures**:

```typescript
// Add more detailed logging
try {
  console.log('Sending Discord notification for:', email);
  await notifyNewUser(email, name, plan, userId);
  console.log('Discord notification succeeded');
} catch (error) {
  console.error('Discord notification failed:', error);
  console.error('Stack trace:', error.stack);
}
```

**For async/await issues**:

```typescript
// Ensure await used
await notifyNewUser(...)  // ✅ CORRECT

notifyNewUser(...)  // ❌ WRONG: Not awaited, may not complete
```

---

## Diagnostic Commands Reference

### Check Configuration

```bash
# Check .env.local exists
ls -la .env.local

# View environment variables (CAREFUL: Contains secrets)
cat .env.local | grep DISCORD

# Check .gitignore includes .env.local
cat .gitignore | grep ".env.local"

# Check for hardcoded webhooks
rg "discord.com/api/webhooks" --type ts

# Check git history for exposed webhooks
git log -S "discord.com/api/webhooks" --all --oneline
```

### Test Webhooks

```bash
# Test webhook directly
curl -X POST "$DISCORD_GENERAL_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{"content":"test"}' \
  -v

# Test via application endpoint
curl -X GET http://localhost:3000/api/discord/test

# Test production
curl -X GET https://hivetechs.io/api/discord/test
```

### Check Cloudflare Secrets

```bash
# List all secrets
wrangler secret list

# View deployment logs
wrangler tail

# Check recent deployments
wrangler deployments list

# Verify account
wrangler whoami
```

### Monitor Discord Integration

```bash
# Watch logs in real-time (development)
tail -f .next/server-logs.txt | grep Discord

# Watch Cloudflare Workers logs (production)
wrangler tail | grep discord

# Count Discord notifications sent
cat logs.txt | grep "Discord notification sent" | wc -l

# Find failed Discord notifications
cat logs.txt | grep "Discord notification failed"
```

---

## Emergency Recovery Procedures

### Emergency 1: All Webhooks Down

**Symptoms**: All Discord notifications failing across all channels.

**Recovery Steps** (15-20 minutes):

1. Check Discord server status: https://discordstatus.com
2. If Discord operational, check webhooks in Discord settings
3. Test each webhook URL individually
4. Recreate any missing webhooks
5. Update environment variables
6. Redeploy application
7. Test all notification types

### Emergency 2: Massive Privacy Leak

**Symptoms**: PII exposed in public Discord channels (emails, names, license
keys).

**Recovery Steps** (10-15 minutes):

1. **IMMEDIATE**: Delete all messages with PII (right-click → Delete)
2. Screenshot exposed data for incident report
3. Fix notification functions (split public/private)
4. Deploy fix immediately
5. Test privacy compliance
6. Notify affected users (if legally required)
7. Document incident

### Emergency 3: Rate Limit Lockout

**Symptoms**: All Discord notifications blocked by rate limits.

**Recovery Steps** (5-10 minutes):

1. Stop application temporarily (prevent more requests)
2. Wait for rate limit reset (60 seconds)
3. Implement rate limiter (if not already)
4. Restart application
5. Monitor rate limit status
6. Adjust notification frequency if needed

---

**Last Updated**: 2025-10-12 **Troubleshooting Guide Version**: v1.0 **Covers
Issues**: 8 common scenarios + emergency procedures
