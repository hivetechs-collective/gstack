# HiveTechs Discord Integration - Complete Reference

Complete documentation of HiveTechs Discord webhook integration including
architecture, implementation details, notification functions, privacy patterns,
and testing procedures.

## 📋 Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [File Locations](#file-locations-critical-reference)
3. [Implementation Details](#implementation-details)
4. [Notification Functions](#notification-functions-8-implemented)
5. [Privacy Protection Pattern](#privacy-protection-pattern)
6. [User Signup Flow Integration](#user-signup-flow-integration)
7. [Testing Procedures](#testing-procedures)
8. [Configuration Requirements](#configuration-requirements)
9. [Critical Patterns to Follow](#critical-patterns-to-follow)

---

## Architecture Overview

### Multi-Channel Strategy

HiveTechs uses a **dual-channel architecture** to separate public community
engagement from private administrative operations:

**Public Channels** (3 channels - NO sensitive data):

- `general` - Community announcements, new member celebrations
- `announcements` - Feature updates, product announcements
- `systemStatus` - Uptime, performance, system alerts

**Private Admin Channels** (3 channels - PII allowed):

- `adminLogs` - User signups with emails, detailed logs
- `userActivity` - User actions, subscription changes
- `metrics` - Analytics, usage statistics, revenue

### Privacy-First Design

**Core Principle**: Never send PII (personally identifiable information) to
public channels.

**Implementation**:

- Separate notification functions: `notifyNewUserPublic()` vs
  `notifyNewUserPrivate()`
- Public notifications: Generic celebrations (plan tier only)
- Private notifications: Full details (email, name, user ID)
- Privacy fix: Commit `d277df9` removed emails from public channels

### Webhook Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Discord Webhook System                    │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Application Event (e.g., user signup)                      │
│           ↓                                                  │
│  notifyNewUser(email, name, plan, userId)                   │
│           ↓                                                  │
│  ┌────────────────────────────┐  ┌──────────────────────┐  │
│  │  notifyNewUserPublic()     │  │ notifyNewUserPrivate()│  │
│  │  - Plan tier only          │  │ - Email, name, ID     │  │
│  │  - Generic celebration     │  │ - Admin logs          │  │
│  └────────────────────────────┘  └──────────────────────┘  │
│           ↓                                ↓                 │
│  sendDiscordMessage('general')   sendDiscordMessage('adminLogs')│
│           ↓                                ↓                 │
│  Discord Public Channel          Discord Private Channel    │
│  (Community visible)             (Admins only)              │
└─────────────────────────────────────────────────────────────┘
```

---

## File Locations (Critical Reference)

### Main Integration File

**Location**: `/src/lib/discord-webhook.ts` **Lines**: 482 total **Purpose**:
Core Discord webhook integration with all notification functions

**Key Sections**:

- Lines 1-18: Webhook URL configuration (⚠️ Line 10 has exposed URL)
- Lines 23-56: TypeScript type definitions (DiscordEmbed, DiscordWebhookPayload)
- Lines 58-66: Color constants (SUCCESS, INFO, WARNING, ERROR, PREMIUM, UPGRADE)
- Lines 68-103: Core `sendDiscordMessage()` function
- Lines 105-146: `notifyNewUserPublic()` - Public celebration
- Lines 148-206: `notifyNewUserPrivate()` - Admin logs with PII
- Lines 208-224: `notifyNewUser()` - Combined notification
- Lines 226-274: `notifySubscriptionChange()` - Subscription updates
- Lines 276-321: `sendDailyAnalytics()` - Metrics dashboard
- Lines 323-359: `notifySystemStatus()` - System alerts
- Lines 361-393: `announceNewFeature()` - Feature announcements
- Lines 395-445: `sendChannelSetupGuide()` - Setup instructions
- Lines 447-482: `sendCommunityRules()` - Community guidelines

### Signup Integration

**Location**: `/src/app/api/auth/signup/route.ts` **Lines**: 115-125 (Discord
notification section) **Purpose**: Integrate Discord notifications into user
signup flow

**Code Reference**:

```typescript
// Line 115-125
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
  // Don't fail the signup if Discord notification fails
}
```

### Testing Endpoint

**Location**: `/src/app/api/discord/test/route.ts` **Lines**: 111 total
**Purpose**: Test Discord webhook configuration and connectivity

**Endpoints**:

- `GET /api/discord/test` - Send channel setup guide and checklist
- `POST /api/discord/test` - Test specific notification types

---

## Implementation Details

### Core Function: `sendDiscordMessage()`

**Location**: `/src/lib/discord-webhook.ts:68-103`

**Signature**:

```typescript
async function sendDiscordMessage(
  payload: DiscordWebhookPayload,
  channel: keyof typeof WEBHOOK_URLS = 'general'
): Promise<boolean>;
```

**Parameters**:

- `payload` - Discord webhook payload (content, username, embeds)
- `channel` - Target channel key ('general', 'announcements', 'adminLogs', etc.)

**Returns**: `boolean` - `true` if successful, `false` if failed

**Error Handling**:

- Returns `false` if webhook URL not configured (doesn't throw)
- Logs errors to console but doesn't propagate
- Safe to use in critical paths (won't break user operations)

**Implementation Details**:

```typescript
export async function sendDiscordMessage(
  payload: DiscordWebhookPayload,
  channel: keyof typeof WEBHOOK_URLS = 'general'
): Promise<boolean> {
  try {
    const webhookUrl = WEBHOOK_URLS[channel];

    // Check if webhook configured
    if (!webhookUrl) {
      console.error(`No webhook URL configured for channel: ${channel}`);
      return false;
    }

    // Send webhook request
    const response = await fetch(webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    // Check response
    if (!response.ok) {
      console.error(
        `Discord webhook failed for ${channel}:`,
        response.status,
        await response.text()
      );
      return false;
    }

    return true;
  } catch (error) {
    console.error(`Discord webhook error for ${channel}:`, error);
    return false;
  }
}
```

### Type Definitions

**Location**: `/src/lib/discord-webhook.ts:23-56`

**DiscordEmbed Interface**:

```typescript
export interface DiscordEmbed {
  title?: string; // Embed title (bold, clickable if URL provided)
  description?: string; // Main embed content
  url?: string; // URL for clickable title
  timestamp?: string; // ISO 8601 timestamp (bottom right)
  color?: number; // Hex color as decimal (0x2ecc71 = green)
  footer?: {
    // Footer section
    text: string; // Footer text
    icon_url?: string; // Small icon next to footer
  };
  image?: {
    // Large image (full width)
    url: string;
  };
  thumbnail?: {
    // Small image (top right)
    url: string;
  };
  author?: {
    // Author section (above title)
    name: string;
    url?: string;
    icon_url?: string;
  };
  fields?: Array<{
    // Structured data fields
    name: string; // Field title (bold)
    value: string; // Field content
    inline?: boolean; // Display side-by-side (max 3 per row)
  }>;
}
```

**DiscordWebhookPayload Interface**:

```typescript
export interface DiscordWebhookPayload {
  content?: string; // Plain text message (above embeds)
  username?: string; // Override webhook username
  avatar_url?: string; // Override webhook avatar
  embeds?: DiscordEmbed[]; // Rich embed messages (max 10)
}
```

### Color Constants

**Location**: `/src/lib/discord-webhook.ts:58-66`

```typescript
export const DISCORD_COLORS = {
  SUCCESS: 0x2ecc71, // Green (#2ecc71) - Successful operations
  INFO: 0x3498db, // Blue (#3498db) - Informational messages
  WARNING: 0xf39c12, // Orange (#f39c12) - Warnings, degraded status
  ERROR: 0xe74c3c, // Red (#e74c3c) - Errors, system down
  PREMIUM: 0xf1c40f, // Gold (#f1c40f) - Premium features, upgrades
  UPGRADE: 0x9b59b6, // Purple (#9b59b6) - Plan upgrades
};
```

**Usage**:

```typescript
const embed: DiscordEmbed = {
  title: 'Operation Successful',
  color: DISCORD_COLORS.SUCCESS, // Green color
  // ...
};
```

---

## Notification Functions (8 Implemented)

### 1. `notifyNewUserPublic()` - Public Celebration

**Location**: `/src/lib/discord-webhook.ts:105-146` **Channel**: `general`
(public) **Privacy**: ✅ NO PII - Only plan tier shown

**Purpose**: Celebrate new community members without exposing sensitive
information.

**Signature**:

```typescript
async function notifyNewUserPublic(plan: string = 'free'): Promise<boolean>;
```

**Parameters**:

- `plan` - Subscription plan ('free', 'basic', 'standard', 'premium', 'team')

**Embed Structure**:

- Title: "🎉 New Member Joined!"
- Description: "Welcome to our newest {plan} tier member!"
- Fields:
  - Plan: Emoji + capitalized plan name (inline)
  - Total Members: "Growing community! 🚀" (inline)
- Footer: "Join us at hivetechs.io"
- Color: SUCCESS (green)

**Example**:

```typescript
await notifyNewUserPublic('premium');
// Sends to #general:
// 🎉 New Member Joined!
// Welcome to our newest premium tier member!
// Plan: 🥇 Premium
// Total Members: Growing community! 🚀
```

### 2. `notifyNewUserPrivate()` - Admin Logs with PII

**Location**: `/src/lib/discord-webhook.ts:148-206` **Channel**: `adminLogs`
(private) **Privacy**: ✅ PII ALLOWED - Email, name, user ID

**Purpose**: Log detailed user information for administrative purposes.

**Signature**:

```typescript
async function notifyNewUserPrivate(
  email: string,
  name: string,
  plan: string = 'free',
  userId?: string
): Promise<boolean>;
```

**Parameters**:

- `email` - User email (PII)
- `name` - User name (PII)
- `plan` - Subscription plan
- `userId` - Internal user ID (optional)

**Embed Structure**:

- Title: "🆕 New User Registration"
- Description: "New user account created"
- Fields:
  - Email: Backtick-wrapped email (inline)
  - Name: User name or "Not provided" (inline)
  - Plan: Capitalized plan name (inline)
  - User ID: Backtick-wrapped ID or "Not available" (inline)
  - Timestamp: Current date/time (inline)
- Footer: "Admin Log - Keep Confidential"
- Color: INFO (blue)

**Privacy Protection**:

```typescript
// Only send if admin channel configured
if (WEBHOOK_URLS.adminLogs) {
  return sendDiscordMessage({ ... }, 'adminLogs')
}

// If not configured, don't send (privacy first!)
console.warn('No admin logs webhook configured - skipping private user notification')
return false
```

### 3. `notifyNewUser()` - Combined Notification

**Location**: `/src/lib/discord-webhook.ts:208-224` **Channels**: `general`
(public) + `adminLogs` (private) **Privacy**: ✅ Split correctly - PII only in
private channel

**Purpose**: Convenience function that sends both public and private
notifications.

**Signature**:

```typescript
async function notifyNewUser(
  email: string,
  name: string,
  plan: string = 'free',
  userId?: string
): Promise<boolean>;
```

**Implementation**:

```typescript
export async function notifyNewUser(
  email: string,
  name: string,
  plan: string = 'free',
  userId?: string
): Promise<boolean> {
  // Send public notification (no email!)
  await notifyNewUserPublic(plan);

  // Send private admin notification (with email)
  await notifyNewUserPrivate(email, name, plan, userId);

  return true;
}
```

**Usage in Signup Flow**:

```typescript
// src/app/api/auth/signup/route.ts:115-125
try {
  await notifyNewUser(
    newUser.email, // PII - goes to adminLogs
    newUser.name || 'Anonymous',
    newUser.subscription_plan_id,
    newUser.id
  );
  console.log('🔔 Discord notifications sent');
} catch (discordError) {
  console.error('🔔 Discord notification failed:', discordError);
  // Don't fail the signup if Discord notification fails
}
```

### 4. `notifySubscriptionChange()` - Subscription Updates

**Location**: `/src/lib/discord-webhook.ts:226-274` **Channel**: `general`
(public) or `adminLogs` (private) - configurable **Privacy**: ⚠️ Contains
email - should use private channel

**Purpose**: Notify about subscription upgrades, downgrades, cancellations.

**Signature**:

```typescript
async function notifySubscriptionChange(
  email: string,
  oldPlan: string,
  newPlan: string,
  action: 'upgrade' | 'downgrade' | 'cancelled'
): Promise<boolean>;
```

**Parameters**:

- `email` - User email (PII - ⚠️ should be private)
- `oldPlan` - Previous subscription plan
- `newPlan` - New subscription plan
- `action` - Type of change

**Embed Structure**:

- Title: "🚀 Plan Upgrade!" (if upgrade) or "📊 Subscription Change"
- Description: "User {action}d their plan" or "User cancelled their
  subscription"
- Fields:
  - User: Email (⚠️ PII - inline)
  - Previous Plan: Capitalized old plan (inline)
  - New Plan: Capitalized new plan or "Cancelled" (inline)
- Footer: "HiveTechs Subscription System"
- Color: UPGRADE (purple) if upgrade, INFO (blue) otherwise
- Content: Optional @mention for upgrades

**Recommendation**: Modify to split public/private like `notifyNewUser()`.

### 5. `sendDailyAnalytics()` - Metrics Dashboard

**Location**: `/src/lib/discord-webhook.ts:276-321` **Channel**: `metrics`
(private) - should be `metrics` not `general` **Privacy**: ✅ Safe - No PII
(aggregated statistics)

**Purpose**: Send daily platform usage summary to metrics dashboard.

**Signature**:

```typescript
async function sendDailyAnalytics(
  activeUsers: number,
  totalConversations: number,
  paidPercentage: number,
  newUsers: number
): Promise<boolean>;
```

**Parameters**:

- `activeUsers` - Number of active users in last 24 hours
- `totalConversations` - Total conversation count
- `paidPercentage` - Percentage of paid users
- `newUsers` - New user signups today

**Embed Structure**:

- Title: "📊 Daily Platform Statistics"
- Description: "HiveTechs usage summary for the last 24 hours"
- Fields:
  - Active Users: Number (inline)
  - Total Conversations: Number (inline)
  - Paid User %: Percentage with 1 decimal (inline)
  - New Users Today: Number (inline)
- Footer: "HiveTechs Analytics"
- Color: INFO (blue)

**Implementation Note**: Currently sends to `general` but should send to
`metrics` channel.

### 6. `notifySystemStatus()` - System Alerts

**Location**: `/src/lib/discord-webhook.ts:323-359` **Channel**: `systemStatus`
(public) **Privacy**: ✅ Safe - No PII (system information)

**Purpose**: Notify community about system status changes (uptime, performance,
outages).

**Signature**:

```typescript
async function notifySystemStatus(
  status: 'operational' | 'degraded' | 'down',
  message: string,
  affectedServices?: string[]
): Promise<boolean>;
```

**Parameters**:

- `status` - Current system status
- `message` - Human-readable status description
- `affectedServices` - Optional array of affected service names

**Embed Structure**:

- Title: "{emoji} System Status: {STATUS}"
  - ✅ Operational (green)
  - ⚠️ Degraded (orange)
  - 🔴 Down (red)
- Description: Status message
- Fields (optional):
  - Affected Services: Comma-separated list
- Footer: "HiveTechs System Monitor"
- Color: Based on status (SUCCESS, WARNING, ERROR)

**Example**:

```typescript
await notifySystemStatus(
  'degraded',
  'API response times elevated due to high traffic',
  ['API Gateway', 'Database']
);
```

### 7. `announceNewFeature()` - Feature Announcements

**Location**: `/src/lib/discord-webhook.ts:361-393` **Channel**: `announcements`
(public) - should be `announcements` not `general` **Privacy**: ✅ Safe - No PII
(product information)

**Purpose**: Announce new features, updates, product launches.

**Signature**:

```typescript
async function announceNewFeature(
  title: string,
  description: string,
  features: string[],
  link?: string
): Promise<boolean>;
```

**Parameters**:

- `title` - Feature name
- `description` - Feature description
- `features` - Array of bullet points (what's new)
- `link` - Optional URL to feature documentation

**Embed Structure**:

- Title: "🎯 New Feature: {title}" (clickable if link provided)
- Description: Feature description
- URL: Optional link to documentation
- Fields:
  - What's New: Bulleted list of features
- Footer: "HiveTechs Product Updates"
- Color: PREMIUM (gold)
- Content: "@everyone" (notify all members)

**Example**:

```typescript
await announceNewFeature(
  'Advanced Analytics Dashboard',
  'Track your team performance with real-time metrics',
  [
    'Live conversation analytics',
    'Team productivity metrics',
    'Custom report builder',
    'Export to CSV/PDF',
  ],
  'https://hivetechs.io/features/analytics'
);
```

### 8. `sendChannelSetupGuide()` - Setup Instructions

**Location**: `/src/lib/discord-webhook.ts:395-445` **Channel**: `adminLogs`
(private) with fallback to `general` **Privacy**: ✅ Safe - No PII (setup
instructions)

**Purpose**: Send setup guide for configuring Discord server channels and
webhooks.

**Signature**:

```typescript
async function sendChannelSetupGuide(): Promise<boolean>;
```

**Embed Structure**:

- Title: "🔧 Discord Channel Setup Required"
- Description: "To properly organize your Discord server, please create these
  channels:"
- Fields:
  - 📢 Public Channels: List of public channels needed
  - 🔒 Private Admin Channels: List of private channels needed
  - ⚙️ Webhook Setup: Instructions for webhook configuration
  - 🔐 Privacy Notice: Privacy policy reminder
- Footer: "Admin Setup Guide - Keep this information secure"
- Color: WARNING (orange)

**Usage**: Called by `/api/discord/test` endpoint during initial setup.

---

## Privacy Protection Pattern

### Privacy Fix History

**Commit**: `d277df9` **Date**: Recent (within last week based on git status)
**Issue**: Emails were being sent to public `#general` channel **Fix**: Split
`notifyNewUser()` into public and private functions

### Privacy Compliance Checklist

Before implementing any Discord notification:

- [ ] **Identify PII**: Does notification contain email, name, address, license
      key, user ID?
- [ ] **Choose Channel**: Public (no PII) or Private (PII allowed)?
- [ ] **Split if Needed**: Separate public celebration from admin logging
- [ ] **Test Privacy**: Verify PII never appears in public channels
- [ ] **Document**: Add privacy notice to notification function
- [ ] **Audit**: Review all notification functions quarterly

### Public vs Private Decision Matrix

| Data Type         | Public Channel      | Private Channel |
| ----------------- | ------------------- | --------------- |
| **Email**         | ❌ NEVER            | ✅ YES          |
| **Name**          | ❌ NEVER            | ✅ YES          |
| **User ID**       | ❌ NEVER            | ✅ YES          |
| **License Key**   | ❌ NEVER            | ✅ YES          |
| **Plan Tier**     | ✅ YES              | ✅ YES          |
| **Signup Count**  | ✅ YES              | ✅ YES          |
| **Analytics**     | ✅ YES (aggregated) | ✅ YES          |
| **System Status** | ✅ YES              | ✅ YES          |

### Privacy-Safe Notification Template

```typescript
// Split public and private notifications
export async function notifyUserAction(
  email: string, // PII
  action: string, // Safe
  details: string // Safe
): Promise<boolean> {
  // Public version (no PII)
  await sendDiscordMessage(
    {
      embeds: [
        {
          title: `✨ ${action}`,
          description: details,
          color: DISCORD_COLORS.SUCCESS,
          // NO email, NO name, NO user ID
        },
      ],
    },
    'general'
  );

  // Private version (with PII)
  if (WEBHOOK_URLS.adminLogs) {
    await sendDiscordMessage(
      {
        embeds: [
          {
            title: `Admin Log: ${action}`,
            fields: [
              { name: 'Email', value: email, inline: true },
              { name: 'Action', value: action, inline: true },
              { name: 'Details', value: details, inline: false },
            ],
            footer: { text: 'Admin Log - Keep Confidential' },
          },
        ],
      },
      'adminLogs'
    );
  }

  return true;
}
```

---

## User Signup Flow Integration

### Complete Signup Flow with Discord Notifications

**File**: `/src/app/api/auth/signup/route.ts` **Lines**: 115-125 (Discord
notification section)

### Signup Flow Diagram

```
User Submits Signup Form
       ↓
Validate Email/Name
       ↓
Check If User Exists
       ↓
Generate License Key
       ↓
Create User in Database (D1)
       ↓
Send Magic Link Email (SMTP2GO) ← Email service
       ↓
📢 DISCORD NOTIFICATIONS (lines 115-125)
       ↓
   ┌─────────────────────────┐
   │ notifyNewUser()         │
   │ - Public: Plan tier     │
   │ - Private: Full details │
   └─────────────────────────┘
       ↓
Return Success Response to User
```

### Code Implementation

**Location**: `/src/app/api/auth/signup/route.ts:115-125`

```typescript
// Notify Discord about new user (public + private channels)
try {
  await notifyNewUser(
    newUser.email, // PII - goes to adminLogs only
    newUser.name || 'Anonymous', // PII - goes to adminLogs only
    newUser.subscription_plan_id, // Safe - both channels
    newUser.id // Internal ID - adminLogs only
  );
  console.log('🔔 Discord notifications sent');
} catch (discordError) {
  console.error('🔔 Discord notification failed:', discordError);
  // Don't fail the signup if Discord notification fails
}
```

### Error Handling Pattern

**Critical Pattern**: Discord notification failures NEVER fail user signups.

**Rationale**:

- User signup is primary operation
- Discord is secondary notification channel
- Discord downtime shouldn't block user registrations
- Email already sent (primary notification)

**Implementation**:

```typescript
try {
  await notifyNewUser(/* ... */);
  console.log('🔔 Discord notifications sent');
} catch (discordError) {
  console.error('🔔 Discord notification failed:', discordError);
  // ⚠️ Don't throw - continue processing
  // ⚠️ Don't return error response
  // ✅ Log error for monitoring
  // ✅ Continue to success response
}
```

**Monitoring**: Check logs for Discord failures, set up alerts for high failure
rates.

---

## Testing Procedures

### Manual Testing via API Endpoint

**Endpoint**: `GET /api/discord/test` **Location**:
`/src/app/api/discord/test/route.ts`

**Development**:

```bash
curl -X GET http://localhost:3000/api/discord/test
```

**Production**:

```bash
curl -X GET https://hivetechs.io/api/discord/test
```

**Expected Response**:

```json
{
  "success": true,
  "message": "Discord webhook test successful! Check your Discord server."
}
```

**Discord Messages Sent**:

1. Channel setup guide (embeds with instructions)
2. Setup checklist (roles, permissions, integrations)

### Test Specific Notification Types

**Endpoint**: `POST /api/discord/test`

**Test User Signup Notification**:

```bash
curl -X POST http://localhost:3000/api/discord/test \
  -H "Content-Type: application/json" \
  -d '{
    "type": "user_signup",
    "plan": "premium"
  }'
```

**Test Announcement**:

```bash
curl -X POST http://localhost:3000/api/discord/test \
  -H "Content-Type: application/json" \
  -d '{
    "type": "announcement",
    "title": "New Feature: Analytics Dashboard",
    "message": "Track your team performance with real-time metrics"
  }'
```

### Direct Webhook Testing (curl)

**Test webhook URL directly**:

```bash
curl -X POST "https://discord.com/api/webhooks/xxx/yyy" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "Test Bot",
    "content": "Testing webhook connectivity",
    "embeds": [{
      "title": "Test Message",
      "description": "This is a test",
      "color": 3447003
    }]
  }'
```

**Expected Response**: `204 No Content` (success)

### Testing Checklist

Before deploying Discord integration:

- [ ] **Environment Variables**: All 6 webhook URLs configured
- [ ] **Public Channels**: Test `general`, `announcements`, `systemStatus`
- [ ] **Private Channels**: Test `adminLogs`, `userActivity`, `metrics`
- [ ] **Privacy**: Verify NO PII in public channels
- [ ] **Error Handling**: Test with invalid webhook URL (should log, not crash)
- [ ] **Signup Flow**: Test complete user signup with Discord notifications
- [ ] **Rate Limiting**: Test burst of 10+ notifications (should not hit 429)
- [ ] **Production Deployment**: Test after deploying to Cloudflare Workers

---

## Configuration Requirements

### Environment Variables (Development)

**File**: `.env.local`

```bash
# Public channel webhooks (NO sensitive data!)
DISCORD_GENERAL_WEBHOOK_URL=https://discord.com/api/webhooks/1234567890/abcdefghij
DISCORD_ANNOUNCEMENTS_WEBHOOK_URL=https://discord.com/api/webhooks/1234567891/abcdefghik
DISCORD_STATUS_WEBHOOK_URL=https://discord.com/api/webhooks/1234567892/abcdefghil

# Private admin channel webhooks (PII allowed)
DISCORD_ADMIN_LOGS_WEBHOOK_URL=https://discord.com/api/webhooks/1234567893/abcdefghim
DISCORD_USER_ACTIVITY_WEBHOOK_URL=https://discord.com/api/webhooks/1234567894/abcdefghin
DISCORD_METRICS_WEBHOOK_URL=https://discord.com/api/webhooks/1234567895/abcdefghio
```

### Cloudflare Secrets (Production)

**Set secrets** (never commit these):

```bash
wrangler secret put DISCORD_GENERAL_WEBHOOK_URL
# Paste webhook URL when prompted

wrangler secret put DISCORD_ANNOUNCEMENTS_WEBHOOK_URL
wrangler secret put DISCORD_STATUS_WEBHOOK_URL
wrangler secret put DISCORD_ADMIN_LOGS_WEBHOOK_URL
wrangler secret put DISCORD_USER_ACTIVITY_WEBHOOK_URL
wrangler secret put DISCORD_METRICS_WEBHOOK_URL
```

**Verify secrets**:

```bash
wrangler secret list
```

### Discord Server Setup

**Create Discord Server**:

1. Open Discord
2. Click "+" → "Create My Own" → "For a club or community"
3. Name: "HiveTechs Community"
4. Upload logo (optional)

**Create Channels**:

1. **Category: PUBLIC** (Everyone can view)
   - `#welcome-and-rules` - Server rules and welcome message
   - `#general` - Community discussion
   - `#announcements` - Product updates (webhook)
   - `#system-status` - Uptime and performance (webhook)
   - `#support` - User support

2. **Category: ADMIN** (Private - Admin role only)
   - `#admin-logs` - User signups with PII (webhook)
   - `#user-activity` - User actions, subscriptions (webhook)
   - `#metrics` - Analytics dashboard (webhook)
   - `#webhook-config` - Webhook management

**Create Webhooks**:

1. Go to Server Settings → Integrations → Webhooks
2. Click "New Webhook"
3. Name: "HiveTechs General"
4. Channel: Select `#general`
5. Copy webhook URL
6. Repeat for all 6 webhook channels

---

## Critical Patterns to Follow

### 1. Privacy Protection Pattern

**Pattern**: Always split public and private notifications.

**Implementation**:

```typescript
// ✅ CORRECT: Split notifications
export async function notifyUserEvent(email: string, event: string) {
  // Public: No PII
  await sendDiscordMessage(
    {
      embeds: [{ title: event, description: 'New activity!' }],
    },
    'general'
  );

  // Private: With PII
  if (WEBHOOK_URLS.adminLogs) {
    await sendDiscordMessage(
      {
        embeds: [{ fields: [{ name: 'Email', value: email }] }],
      },
      'adminLogs'
    );
  }
}

// ❌ WRONG: PII in public channel
export async function notifyUserEvent(email: string, event: string) {
  await sendDiscordMessage(
    {
      embeds: [
        {
          title: event,
          fields: [{ name: 'Email', value: email }], // 🚨 PII exposed!
        },
      ],
    },
    'general'
  );
}
```

### 2. Error Handling Pattern

**Pattern**: Never fail primary operations due to Discord errors.

**Implementation**:

```typescript
// ✅ CORRECT: Catch and log, don't propagate
try {
  await notifyNewUser(email, name, plan);
  console.log('Discord notification sent');
} catch (error) {
  console.error('Discord notification failed:', error);
  // Don't throw - continue processing
}

// ❌ WRONG: Let error propagate
await notifyNewUser(email, name, plan); // Will throw and fail signup
```

### 3. Webhook Configuration Pattern

**Pattern**: Check webhook exists before sending, fail gracefully.

**Implementation**:

```typescript
// ✅ CORRECT: Check before sending
const webhookUrl = WEBHOOK_URLS[channel];
if (!webhookUrl) {
  console.error(`No webhook URL configured for channel: ${channel}`);
  return false; // Graceful failure
}

// ❌ WRONG: Assume webhook exists
const response = await fetch(WEBHOOK_URLS[channel]); // Will throw if undefined
```

### 4. Environment Variable Pattern

**Pattern**: All webhook URLs in environment variables, never hardcoded.

**Implementation**:

```typescript
// ✅ CORRECT: Environment variable
const WEBHOOK_URLS = {
  general: process.env.DISCORD_GENERAL_WEBHOOK_URL,
  // ...
};

// ❌ WRONG: Hardcoded URL
const WEBHOOK_URLS = {
  general: 'https://discord.com/api/webhooks/1234567890/abcdef', // 🚨 Exposed!
};
```

**Current Issue**: Line 10 has hardcoded fallback - needs removal.

### 5. Channel Targeting Pattern

**Pattern**: Route notifications to appropriate channels based on content.

**Decision Matrix**:

```typescript
// User signup → Both channels
notifyNewUserPublic(plan); // general channel
notifyNewUserPrivate(email); // adminLogs channel

// Subscription change → adminLogs (has PII)
notifySubscriptionChange(); // adminLogs channel

// System status → systemStatus (no PII)
notifySystemStatus(); // systemStatus channel

// Analytics → metrics (aggregated, no PII)
sendDailyAnalytics(); // metrics channel

// Feature announcement → announcements (no PII)
announceNewFeature(); // announcements channel
```

---

## Summary

### Key Takeaways

1. **Multi-Channel Architecture**: 6 channels (3 public, 3 private) for proper
   separation
2. **Privacy First**: Split notifications to separate PII from public channels
3. **Error Handling**: Discord failures never fail user operations
4. **Environment Variables**: All webhook URLs configured via environment
5. **8 Notification Functions**: Complete suite for user signups, subscriptions,
   analytics, status
6. **Testing Coverage**: Manual and automated testing via `/api/discord/test`

### Next Steps

1. **Security**: Rotate exposed webhook URL on line 10
2. **Configuration**: Set all 6 environment variables in production
3. **Testing**: Run complete test suite via `/api/discord/test`
4. **Monitoring**: Set up alerts for Discord notification failures
5. **Documentation**: Update team wiki with Discord setup procedures

---

**Last Updated**: 2025-10-12 **Integration Version**: v1.0 **Status**:
Production-ready (pending webhook rotation)
