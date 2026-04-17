# Discord Webhook Configuration Guide

Complete setup instructions for configuring Discord webhooks for HiveTechs
integration including server setup, channel creation, webhook configuration,
environment variables, and deployment to Cloudflare Workers.

## 📋 Table of Contents

1. [Discord Server Setup](#discord-server-setup)
2. [Channel Configuration (6 Channels)](#channel-configuration-6-channels)
3. [Webhook Creation](#webhook-creation-procedures)
4. [Environment Variable Setup](#environment-variable-setup)
5. [Cloudflare Workers Deployment](#cloudflare-workers-deployment)
6. [Testing Procedures](#testing-procedures)
7. [Troubleshooting Common Setup Issues](#troubleshooting-common-setup-issues)

---

## Discord Server Setup

### Create New Discord Server

**Step 1: Create Server**

1. Open Discord desktop or web application
2. Click the "+" icon in server list (left sidebar)
3. Select "Create My Own"
4. Choose "For a club or community"
5. Server name: **"HiveTechs Community"** (or your company name)
6. Upload server icon (optional):
   - Recommended: Company logo
   - Size: 512x512px minimum
   - Format: PNG, JPG, GIF

**Step 2: Configure Server Settings**

1. Click server name → "Server Settings"
2. Navigate to "Overview"
   - Verification Level: **Medium** (recommended)
   - Explicit Content Filter: **Scan media from all members**
   - Default Notifications: **Only @mentions**
3. Navigate to "Roles"
   - Create roles (see Role Configuration below)
4. Navigate to "Channels"
   - Create categories and channels (see next section)

### Role Configuration

Create these roles with appropriate permissions:

**1. Founder** (Red color: #e74c3c)

- Permissions: Administrator
- Members: Company founders

**2. Admin** (Orange color: #f39c12)

- Permissions:
  - Manage Server
  - Manage Channels
  - Manage Webhooks
  - Kick Members
  - Ban Members
  - View Audit Log
- Members: Core team members

**3. Premium User** (Gold color: #f1c40f)

- Permissions:
  - Read Messages
  - Send Messages
  - Embed Links
  - Attach Files
- Members: Paying customers (premium/team plans)

**4. Trial User** (Light Blue color: #3498db)

- Permissions:
  - Read Messages
  - Send Messages
  - Limited Embed Links
- Members: Free trial users

**5. Support Team** (Blue color: #2ecc71)

- Permissions:
  - Read Messages
  - Send Messages
  - Manage Messages
  - Embed Links
  - Attach Files
- Members: Customer support staff

---

## Channel Configuration (6 Channels)

### Channel Structure Overview

```
📢 PUBLIC CHANNELS (Everyone can view)
├── 📋 #welcome-and-rules (Text)
├── 💬 #general (Text) [WEBHOOK]
├── 📣 #announcements (Text) [WEBHOOK]
├── 🟢 #system-status (Text) [WEBHOOK]
└── 🆘 #support (Text)

🔒 ADMIN CHANNELS (Admin role only)
├── 📝 #admin-logs (Text) [WEBHOOK]
├── 👤 #user-activity (Text) [WEBHOOK]
├── 📊 #metrics (Text) [WEBHOOK]
└── ⚙️ #webhook-config (Text)
```

### Category 1: PUBLIC

**Create category**:

1. Right-click server name → "Create Category"
2. Name: **"PUBLIC"**
3. Permissions:
   - @everyone: ✅ Read Messages
   - Sync permissions to all channels

**Channels to create**:

#### #welcome-and-rules

- **Purpose**: Server rules and welcome message
- **Type**: Text channel
- **Permissions**: @everyone can read, only admins can write
- **Setup**:
  - Post server rules (use `/sendCommunityRules()` function)
  - Pin rules message
  - Disable @everyone from sending messages

#### #general (WEBHOOK)

- **Purpose**: Community discussion, new member celebrations
- **Type**: Text channel
- **Permissions**: @everyone can read and write
- **Webhook**: Required - User signup notifications (NO PII)
- **Setup**:
  - Create webhook (see Webhook Creation section)
  - Environment variable: `DISCORD_GENERAL_WEBHOOK_URL`

#### #announcements (WEBHOOK)

- **Purpose**: Product updates, feature releases
- **Type**: Announcement channel
- **Permissions**:
  - @everyone can read
  - Only admins can write
  - Followers enabled (users can follow in other servers)
- **Webhook**: Required - Feature announcements
- **Setup**:
  - Right-click channel → "Edit Channel"
  - Channel Type: Select "Announcement Channel"
  - Create webhook
  - Environment variable: `DISCORD_ANNOUNCEMENTS_WEBHOOK_URL`

#### #system-status (WEBHOOK)

- **Purpose**: Uptime monitoring, performance alerts
- **Type**: Text channel
- **Permissions**: @everyone can read, only webhooks can write
- **Webhook**: Required - System status updates
- **Setup**:
  - Create webhook
  - Disable @everyone from sending messages
  - Environment variable: `DISCORD_STATUS_WEBHOOK_URL`

#### #support

- **Purpose**: User support, troubleshooting
- **Type**: Text channel
- **Permissions**:
  - @everyone can read and write
  - Support Team: Can manage messages
- **Webhook**: Not required
- **Setup**:
  - Enable forum (optional): Right-click → "Edit Channel" → Enable Forum
  - Tags: Bug, Question, Feedback

### Category 2: ADMIN

**Create category**:

1. Right-click server name → "Create Category"
2. Name: **"ADMIN"**
3. Permissions:
   - @everyone: ❌ Read Messages (disabled)
   - Admin role: ✅ Read Messages, ✅ Send Messages
   - Founder role: ✅ All permissions

**Channels to create**:

#### #admin-logs (WEBHOOK) ⚠️ Contains PII

- **Purpose**: User signups with emails, detailed admin logs
- **Type**: Text channel
- **Permissions**: Admin role only
- **Webhook**: Required - User signup with PII
- **Privacy**: ⚠️ Contains emails, names, user IDs
- **Setup**:
  - Create webhook
  - Pin privacy notice: "⚠️ This channel contains PII - Keep confidential"
  - Environment variable: `DISCORD_ADMIN_LOGS_WEBHOOK_URL`

#### #user-activity (WEBHOOK)

- **Purpose**: User actions, subscription changes
- **Type**: Text channel
- **Permissions**: Admin role only
- **Webhook**: Required - Subscription updates
- **Setup**:
  - Create webhook
  - Environment variable: `DISCORD_USER_ACTIVITY_WEBHOOK_URL`

#### #metrics (WEBHOOK)

- **Purpose**: Analytics dashboard, usage statistics
- **Type**: Text channel
- **Permissions**: Admin and Founder roles only
- **Webhook**: Required - Daily analytics
- **Setup**:
  - Create webhook
  - Pin dashboard template
  - Environment variable: `DISCORD_METRICS_WEBHOOK_URL`

#### #webhook-config

- **Purpose**: Webhook management, configuration docs
- **Type**: Text channel
- **Permissions**: Founder role only
- **Webhook**: Not required
- **Setup**:
  - Post webhook URLs (in DMs or secure notes, NOT in channel!)
  - Document environment variable names
  - Pin setup guide message

---

## Webhook Creation Procedures

### For Each Channel (Repeat 6 Times)

**Step 1: Navigate to Channel Settings**

1. Right-click channel (e.g., #general)
2. Select "Edit Channel"
3. Navigate to "Integrations" tab
4. Click "Create Webhook"

**Step 2: Configure Webhook**

1. **Name**: Choose descriptive name
   - General: "HiveTechs General Bot"
   - Admin Logs: "HiveTechs Admin Logger"
   - Announcements: "HiveTechs Updates"
   - System Status: "HiveTechs Status Monitor"
   - User Activity: "HiveTechs Activity Tracker"
   - Metrics: "HiveTechs Analytics Bot"

2. **Avatar** (optional but recommended):
   - Upload company logo
   - Size: 128x128px minimum
   - Format: PNG or JPG

3. **Channel**: Verify correct channel selected

**Step 3: Copy Webhook URL**

1. Click "Copy Webhook URL" button
2. ⚠️ **IMPORTANT**: Do NOT share this URL in public channels
3. ⚠️ **IMPORTANT**: Do NOT commit this URL to git

**Webhook URL Format**:

```
https://discord.com/api/webhooks/{webhook_id}/{webhook_token}
```

**Example**:

```
https://discord.com/api/webhooks/1234567890123456789/AbCdEfGhIjKlMnOpQrStUvWxYz1234567890AbCdEfGhIjKlMnOpQrStUvWxYz12
```

**Components**:

- `webhook_id`: Unique identifier (18-19 digits)
- `webhook_token`: Secret token (64+ characters)

**Step 4: Save Webhook Configuration**

1. Click "Save Changes" in Discord
2. Store webhook URL securely (password manager, `.env.local`)
3. Do NOT close settings yet - verify webhook created:
   - Should appear in "Webhooks" list
   - Shows webhook name and avatar

**Step 5: Test Webhook (Optional)**

```bash
# Test with curl (DO NOT log this command!)
curl -X POST "YOUR_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "Test Bot",
    "content": "✅ Webhook configuration successful! (Delete this message)"
  }'
```

Expected: Message appears in Discord channel

### Webhook Summary Checklist

After creating all webhooks, you should have:

- [ ] **#general webhook**: For public user signup celebrations
- [ ] **#announcements webhook**: For feature releases
- [ ] **#system-status webhook**: For uptime monitoring
- [ ] **#admin-logs webhook**: For user signups with emails (PII)
- [ ] **#user-activity webhook**: For subscription changes
- [ ] **#metrics webhook**: For daily analytics

**Security reminder**: Never share webhook URLs in:

- Public Discord channels
- Git commits
- Slack/Teams messages
- Documentation (use placeholders instead)

---

## Environment Variable Setup

### Development Environment

**File**: `.env.local` (create in project root)

**Template**:

```bash
# ============================================
# Discord Webhook Configuration
# Last Updated: 2025-10-12
# ============================================

# PUBLIC CHANNELS (NO PII)
# General community discussion and new member celebrations
DISCORD_GENERAL_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN

# Product announcements and feature releases
DISCORD_ANNOUNCEMENTS_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN

# System status updates and performance alerts
DISCORD_STATUS_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN

# PRIVATE ADMIN CHANNELS (PII ALLOWED)
# User signups with emails and detailed logs (SENSITIVE)
DISCORD_ADMIN_LOGS_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN

# User activity and subscription changes
DISCORD_USER_ACTIVITY_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN

# Daily analytics and usage statistics
DISCORD_METRICS_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN

# ============================================
# Security Notes:
# - Never commit this file to git
# - Rotate webhooks every 6 months
# - Store backup copy in password manager
# ============================================
```

**Setup Steps**:

1. Create `.env.local` file in project root:

   ```bash
   touch .env.local
   ```

2. Copy template above into `.env.local`

3. Replace `YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN` with actual webhook URLs

4. Verify `.gitignore` includes `.env.local`:

   ```bash
   cat .gitignore | grep ".env.local"
   # Should output: .env.local
   ```

5. If not in `.gitignore`, add it:
   ```bash
   echo ".env.local" >> .gitignore
   git add .gitignore
   git commit -m "chore: add .env.local to gitignore"
   ```

**Test configuration**:

```bash
# Start development server
npm run dev

# Test Discord integration
curl -X GET http://localhost:3000/api/discord/test

# Expected: {"success":true,"message":"Discord webhook test successful!"}
```

### Create Template for Team

**File**: `.env.local.example` (commit to git)

```bash
# Discord Webhook Configuration Template
# Copy to .env.local and fill in webhook URLs

# PUBLIC CHANNELS
DISCORD_GENERAL_WEBHOOK_URL=
DISCORD_ANNOUNCEMENTS_WEBHOOK_URL=
DISCORD_STATUS_WEBHOOK_URL=

# PRIVATE ADMIN CHANNELS
DISCORD_ADMIN_LOGS_WEBHOOK_URL=
DISCORD_USER_ACTIVITY_WEBHOOK_URL=
DISCORD_METRICS_WEBHOOK_URL=

# Setup instructions: See docs/discord-webhook-setup.md
```

**Commit template**:

```bash
git add .env.local.example
git commit -m "docs: add Discord webhook configuration template"
git push origin main
```

---

## Cloudflare Workers Deployment

### Prerequisites

- Cloudflare account with Workers enabled
- Wrangler CLI installed: `npm install -g wrangler`
- Authenticated with Cloudflare: `wrangler login`

### Set Production Secrets

**Step 1: Navigate to project directory**

```bash
cd /path/to/hivetechs-website
```

**Step 2: Set each secret**

```bash
# Public channel webhooks
wrangler secret put DISCORD_GENERAL_WEBHOOK_URL
# Prompt: Enter a secret value:
# Paste webhook URL, press Enter
# Output: ✅ Successfully created secret for key: DISCORD_GENERAL_WEBHOOK_URL

wrangler secret put DISCORD_ANNOUNCEMENTS_WEBHOOK_URL
# Paste webhook URL, press Enter

wrangler secret put DISCORD_STATUS_WEBHOOK_URL
# Paste webhook URL, press Enter

# Private admin channel webhooks
wrangler secret put DISCORD_ADMIN_LOGS_WEBHOOK_URL
# Paste webhook URL, press Enter

wrangler secret put DISCORD_USER_ACTIVITY_WEBHOOK_URL
# Paste webhook URL, press Enter

wrangler secret put DISCORD_METRICS_WEBHOOK_URL
# Paste webhook URL, press Enter
```

**Step 3: Verify secrets set**

```bash
wrangler secret list

# Expected output:
# [
#   {
#     "name": "DISCORD_GENERAL_WEBHOOK_URL",
#     "type": "secret_text"
#   },
#   {
#     "name": "DISCORD_ANNOUNCEMENTS_WEBHOOK_URL",
#     "type": "secret_text"
#   },
#   {
#     "name": "DISCORD_STATUS_WEBHOOK_URL",
#     "type": "secret_text"
#   },
#   {
#     "name": "DISCORD_ADMIN_LOGS_WEBHOOK_URL",
#     "type": "secret_text"
#   },
#   {
#     "name": "DISCORD_USER_ACTIVITY_WEBHOOK_URL",
#     "type": "secret_text"
#   },
#   {
#     "name": "DISCORD_METRICS_WEBHOOK_URL",
#     "type": "secret_text"
#   }
# ]
```

### Deploy to Cloudflare Workers

**Step 1: Build production bundle**

```bash
npm run build

# Expected output:
# > next build
# ...
# ✓ Compiled successfully
```

**Step 2: Deploy to Cloudflare**

```bash
wrangler deploy

# Output:
# ⛅️ wrangler 3.x.x
# ------------------
# Total Upload: xxx.xx KiB / gzip: xxx.xx KiB
# Uploaded hivetechs-website (x.xx sec)
# Published hivetechs-website (x.xx sec)
#   https://hivetechs-website.workers.dev
# Current Deployment ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**Step 3: Test production deployment**

```bash
# Test Discord integration in production
curl -X GET https://hivetechs.io/api/discord/test

# Expected: {"success":true}
# Check Discord: Should see test messages in channels
```

### Cloudflare Dashboard Configuration

**Alternative: Set secrets via dashboard**

1. Go to https://dash.cloudflare.com
2. Navigate to Workers & Pages
3. Click your worker (e.g., "hivetechs-website")
4. Go to "Settings" → "Variables"
5. Under "Environment Variables":
   - Click "Add variable"
   - Type: "Secret"
   - Variable name: `DISCORD_GENERAL_WEBHOOK_URL`
   - Value: Paste webhook URL
   - Click "Save"
6. Repeat for all 6 webhook URLs

**Verify via dashboard**:

- All 6 secrets should appear in "Variables" list
- Type: "Secret" (encrypted)
- Value: "••••••••" (hidden)

---

## Testing Procedures

### Initial Setup Test

**Test 1: Webhook connectivity**

```bash
# Development
curl -X GET http://localhost:3000/api/discord/test

# Production
curl -X GET https://hivetechs.io/api/discord/test

# Expected response:
{
  "success": true,
  "message": "Discord webhook test successful! Check your Discord server."
}
```

**Verify in Discord**:

- Check #general: Should see "Discord Channel Setup Required" message
- Check #general: Should see "Discord Setup Checklist" message

### Test Individual Channels

**Test each webhook URL directly**:

```bash
# Test #general webhook
curl -X POST "$DISCORD_GENERAL_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "Setup Test",
    "content": "✅ #general webhook working! (Delete this message)"
  }'

# Repeat for each channel:
# - DISCORD_ANNOUNCEMENTS_WEBHOOK_URL → #announcements
# - DISCORD_STATUS_WEBHOOK_URL → #system-status
# - DISCORD_ADMIN_LOGS_WEBHOOK_URL → #admin-logs
# - DISCORD_USER_ACTIVITY_WEBHOOK_URL → #user-activity
# - DISCORD_METRICS_WEBHOOK_URL → #metrics
```

**Expected**: Message appears in corresponding Discord channel

### Test Integration with Signup Flow

**Test complete user signup with Discord notifications**:

```bash
# Test signup (development)
curl -X POST http://localhost:3000/api/auth/signup \
  -H "Content-Type: application/json" \
  -d '{
    "email": "test@example.com",
    "name": "Test User"
  }'

# Expected response:
{
  "success": true,
  "message": "Account created successfully...",
  "user": { ... }
}
```

**Verify in Discord**:

1. Check #general:
   - Should see: "🎉 New Member Joined!"
   - Description: "Welcome to our newest free tier member!"
   - Fields: Plan = "🆓 Free", Total Members = "Growing community! 🚀"
   - ⚠️ Should NOT contain email or name

2. Check #admin-logs (if webhook configured):
   - Should see: "🆕 New User Registration"
   - Fields: Email = `test@example.com`, Name = "Test User"
   - ✅ Should contain full details (PII)

### Test Privacy Compliance

**Privacy test checklist**:

- [ ] **Public channel (#general)**: No emails, no names, no user IDs
- [ ] **Public channel (#announcements)**: No user data
- [ ] **Public channel (#system-status)**: No user data
- [ ] **Private channel (#admin-logs)**: Contains emails (if configured)
- [ ] **Private channel (#user-activity)**: Contains user actions
- [ ] **Private channel (#metrics)**: Aggregated data only

**Manual verification**:

1. Scroll through #general channel history
2. Search for email pattern: `Ctrl+F` → `@`
3. If any emails found: 🚨 PRIVACY LEAK - Fix immediately
4. Repeat for #announcements and #system-status

### Performance Testing

**Rate limiting test** (optional):

```bash
# Send 10 notifications rapidly
for i in {1..10}; do
  curl -X POST http://localhost:3000/api/discord/test \
    -H "Content-Type: application/json" \
    -d '{"type":"user_signup","plan":"free"}' &
done
wait

# Check logs for rate limiting
# Should NOT see "429 Too Many Requests" (if rate limiter implemented)
```

---

## Troubleshooting Common Setup Issues

### Issue 1: Webhook URL Not Working (404)

**Symptoms**:

- Curl returns 404 Not Found
- Test endpoint fails: `{"success":false}`
- No messages appearing in Discord

**Diagnosis**:

```bash
curl -X POST "$DISCORD_GENERAL_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{"content":"test"}'

# If 404: Webhook deleted or URL incorrect
```

**Solutions**:

1. **Verify webhook exists**:
   - Go to Discord → Server Settings → Integrations → Webhooks
   - Check if webhook still listed
   - If not listed: Webhook was deleted

2. **Check webhook URL format**:
   - Should be: `https://discord.com/api/webhooks/{id}/{token}`
   - Common mistakes:
     - Missing token (only ID)
     - Extra spaces or newlines
     - HTTP instead of HTTPS

3. **Recreate webhook**:
   - Follow "Webhook Creation Procedures" section
   - Update `.env.local` with new URL
   - Update Cloudflare secrets:
     `wrangler secret put DISCORD_GENERAL_WEBHOOK_URL`
   - Test again

### Issue 2: Environment Variables Not Loading

**Symptoms**:

- Logs show: `No webhook URL configured for channel: general`
- `process.env.DISCORD_GENERAL_WEBHOOK_URL` is `undefined`

**Diagnosis**:

```bash
# Check .env.local exists
ls -la .env.local

# Check environment variable syntax
cat .env.local | grep DISCORD_GENERAL_WEBHOOK_URL
```

**Solutions**:

1. **Verify .env.local exists**:

   ```bash
   # If missing, create it
   cp .env.local.example .env.local
   # Fill in webhook URLs
   ```

2. **Check syntax** (common mistakes):

   ```bash
   # ❌ WRONG: Spaces around =
   DISCORD_GENERAL_WEBHOOK_URL = https://...

   # ✅ CORRECT: No spaces
   DISCORD_GENERAL_WEBHOOK_URL=https://...

   # ❌ WRONG: Quotes inside URL
   DISCORD_GENERAL_WEBHOOK_URL="https://..."

   # ✅ CORRECT: No quotes (Next.js handles this)
   DISCORD_GENERAL_WEBHOOK_URL=https://...
   ```

3. **Restart development server**:

   ```bash
   # Stop server (Ctrl+C)
   # Start again
   npm run dev
   ```

4. **Verify environment variable loaded**:
   ```typescript
   // Add temporary debug log
   console.log(
     'DISCORD_GENERAL_WEBHOOK_URL:',
     process.env.DISCORD_GENERAL_WEBHOOK_URL
   );
   // Should output: DISCORD_GENERAL_WEBHOOK_URL: https://discord.com/api/webhooks/...
   ```

### Issue 3: Cloudflare Secrets Not Working

**Symptoms**:

- Works in development, fails in production
- Production logs: `No webhook URL configured`
- Wrangler shows secrets set

**Diagnosis**:

```bash
# Check secrets exist
wrangler secret list

# Check deployment logs
wrangler tail
```

**Solutions**:

1. **Verify secrets set correctly**:

   ```bash
   # List all secrets
   wrangler secret list

   # Should show all 6 webhooks:
   # - DISCORD_GENERAL_WEBHOOK_URL
   # - DISCORD_ANNOUNCEMENTS_WEBHOOK_URL
   # - DISCORD_STATUS_WEBHOOK_URL
   # - DISCORD_ADMIN_LOGS_WEBHOOK_URL
   # - DISCORD_USER_ACTIVITY_WEBHOOK_URL
   # - DISCORD_METRICS_WEBHOOK_URL
   ```

2. **Recreate missing secrets**:

   ```bash
   # Delete and recreate
   wrangler secret delete DISCORD_GENERAL_WEBHOOK_URL
   wrangler secret put DISCORD_GENERAL_WEBHOOK_URL
   # Paste webhook URL
   ```

3. **Redeploy after setting secrets**:

   ```bash
   wrangler deploy
   ```

4. **Check access in worker code**:
   ```typescript
   // Workers access secrets via env parameter
   export default {
     async fetch(request, env) {
       console.log('Has webhook:', !!env.DISCORD_GENERAL_WEBHOOK_URL);
       // Should log: Has webhook: true
     },
   };
   ```

### Issue 4: Privacy Leak (PII in Public Channel)

**Symptoms**:

- Emails appearing in #general
- User names in #announcements
- User IDs in #system-status

**Diagnosis**:

```bash
# Check Discord #general channel
# Search for: @ (email indicator)
# If found: Privacy leak!
```

**Solutions**:

1. **Delete exposed messages immediately**:
   - Right-click message → Delete
   - Repeat for all messages with PII

2. **Fix notification function**:

   ```typescript
   // BEFORE (privacy leak):
   await sendDiscordMessage(
     {
       embeds: [
         {
           fields: [
             { name: 'Email', value: email }, // 🚨 PII in public!
           ],
         },
       ],
     },
     'general'
   );

   // AFTER (privacy safe):
   // Public: No PII
   await sendDiscordMessage(
     {
       embeds: [
         {
           title: 'New member joined!',
           description: 'Welcome!',
           // NO email, NO name
         },
       ],
     },
     'general'
   );

   // Private: With PII
   if (WEBHOOK_URLS.adminLogs) {
     await sendDiscordMessage(
       {
         embeds: [
           {
             fields: [{ name: 'Email', value: email }],
           },
         ],
       },
       'adminLogs'
     );
   }
   ```

3. **Test privacy fix**:

   ```bash
   # Test signup
   curl -X POST http://localhost:3000/api/auth/signup \
     -H "Content-Type: application/json" \
     -d '{"email":"privacy-test@example.com","name":"Privacy Test"}'

   # Check #general: Should NOT see email
   # Check #admin-logs: Should see email
   ```

---

**Last Updated**: 2025-10-12 **Configuration Version**: v1.0 **Next Review**:
When adding new channels or webhooks
