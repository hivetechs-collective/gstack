# Discord Expert Knowledge Base

Complete reference for HiveTechs Discord webhook integration, security best
practices, and community management.

## 📚 Knowledge Base Files

### 1. HiveTechs Discord Integration (`hivetechs-discord-integration.md`)

**Complete integration reference with implementation details**

- Architecture overview (multi-channel strategy)
- Implementation details from `src/lib/discord-webhook.ts`
- 8 notification functions with code references
- User signup flow integration
- Privacy protection patterns (public vs private)
- Testing endpoints and procedures
- Configuration requirements

**Use this for**: Understanding complete integration, finding code references,
implementation patterns

### 2. Discord Security Best Practices (`discord-security-best-practices.md`)

**Security procedures and privacy compliance**

- Webhook URL rotation procedures (5-step process)
- Environment variable configuration (development + production)
- Cloudflare secrets management (`wrangler secret put`)
- Privacy guidelines (GDPR compliance)
- Rate limiting strategies (30 requests/60 seconds)
- Monitoring and alert configuration

**Use this for**: Security issues, webhook exposure incidents, privacy
compliance, secret management

### 3. Discord Webhook Configuration (`discord-webhook-configuration.md`)

**Complete setup instructions from scratch**

- Discord server creation steps
- Channel setup (6 channels: 3 public, 3 private)
- Webhook creation procedures (step-by-step screenshots)
- Environment variable setup (`.env.local`, Cloudflare secrets)
- Testing procedures (`/api/discord/test`)
- Deployment to Cloudflare Workers

**Use this for**: Initial setup, adding new channels, webhook configuration,
environment setup

### 4. Troubleshooting Guide (`troubleshooting-guide.md`)

**Common issues and solutions**

- Issue 1: Webhook URL not working (404/401 errors)
- Issue 2: Privacy leak (PII in public channels)
- Issue 3: Rate limiting errors (429 responses)
- Issue 4: Configuration mistakes (missing environment variables)
- Issue 5: Environment variable issues (undefined webhooks)
- Issue 6: Cloudflare secret problems (production failures)
- Diagnostic commands and recovery procedures

**Use this for**: Debugging failures, error recovery, production issues

## 🎯 Quick Reference

### Common Tasks

**Setup Discord Integration**:

1. Read: `discord-webhook-configuration.md` → "Discord Server Setup"
2. Create 6 channels (3 public, 3 private)
3. Generate webhook URLs for each channel
4. Configure environment variables
5. Test with `/api/discord/test`

**Rotate Exposed Webhook**:

1. Read: `discord-security-best-practices.md` → "Webhook URL Rotation Steps"
2. Delete old webhook in Discord settings
3. Create new webhook for same channel
4. Update `.env.local` and Cloudflare secrets
5. Test and verify

**Fix Privacy Leak**:

1. Read: `discord-security-best-practices.md` → "Privacy Guidelines"
2. Identify PII in public channels (emails, license keys)
3. Split notifications: `notifyNewUserPublic()` + `notifyNewUserPrivate()`
4. Route sensitive data to private admin channels only
5. Audit and test

**Add New Notification**:

1. Read: `hivetechs-discord-integration.md` → "Notification Functions"
2. Create new function following existing patterns
3. Choose appropriate channel (public vs private)
4. Add color coding and embed structure
5. Integrate with application logic
6. Test with `/api/discord/test`

### File Locations (Quick Access)

| Component              | File Path                            | Lines     |
| ---------------------- | ------------------------------------ | --------- |
| **Main Integration**   | `/src/lib/discord-webhook.ts`        | 482 lines |
| **Signup Integration** | `/src/app/api/auth/signup/route.ts`  | 115-125   |
| **Testing Endpoint**   | `/src/app/api/discord/test/route.ts` | 111 lines |
| **Type Definitions**   | `/src/lib/discord-webhook.ts`        | 23-56     |

### Environment Variables

**Development (`.env.local`)**:

```bash
DISCORD_GENERAL_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy
DISCORD_ANNOUNCEMENTS_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy
DISCORD_STATUS_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy
DISCORD_ADMIN_LOGS_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy
DISCORD_USER_ACTIVITY_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy
DISCORD_METRICS_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy
```

**Production (Cloudflare Secrets)**:

```bash
wrangler secret put DISCORD_GENERAL_WEBHOOK_URL
wrangler secret put DISCORD_ADMIN_LOGS_WEBHOOK_URL
# ... repeat for all 6 webhooks
```

### Channel Strategy

**Public Channels** (NO sensitive data):

- `general` - Community announcements, new member celebrations
- `announcements` - Feature updates, product announcements
- `systemStatus` - Uptime, performance, system alerts

**Private Admin Channels** (PII allowed):

- `adminLogs` - User signups with emails, detailed logs
- `userActivity` - User actions, subscription changes
- `metrics` - Analytics, usage statistics, revenue

### Color Codes

```typescript
DISCORD_COLORS = {
  SUCCESS: 0x2ecc71, // Green (#2ecc71)
  INFO: 0x3498db, // Blue (#3498db)
  WARNING: 0xf39c12, // Orange (#f39c12)
  ERROR: 0xe74c3c, // Red (#e74c3c)
  PREMIUM: 0xf1c40f, // Gold (#f1c40f)
  UPGRADE: 0x9b59b6, // Purple (#9b59b6)
};
```

### Rate Limits

- **Per Webhook**: 30 requests per 60 seconds (0.5 requests/second)
- **Global**: 50 requests per second per application
- **Burst**: Up to 5 requests instantly
- **429 Response**: Retry after `Retry-After` seconds

## 🔧 Debugging Commands

**Test webhook locally**:

```bash
curl -X GET http://localhost:3000/api/discord/test
```

**Test webhook with curl**:

```bash
curl -X POST "https://discord.com/api/webhooks/xxx/yyy" \
  -H "Content-Type: application/json" \
  -d '{"content": "Test message"}'
```

**Verify environment variables**:

```bash
# Development
cat .env.local | grep DISCORD

# Production
wrangler secret list
```

**Search for webhook URLs in code**:

```bash
rg "discord.com/api/webhooks" --type ts
```

**Check git history for exposed webhooks**:

```bash
git log -S "discord.com/api/webhooks" --all
```

## 🚨 Emergency Procedures

**Webhook Exposed (IMMEDIATE ACTION REQUIRED)**:

1. ⚠️ **STOP**: Don't commit/push any more changes
2. 🗑️ **DELETE**: Remove webhook in Discord server settings immediately
3. 🆕 **CREATE**: Generate new webhook URL for same channel
4. 🔧 **UPDATE**: Replace webhook URL in `.env.local` and Cloudflare secrets
5. ✅ **TEST**: Verify new webhook works with `/api/discord/test`
6. 📝 **AUDIT**: Search git history for exposed URL, document incident

**Privacy Leak (PII in Public Channel)**:

1. ⚠️ **VERIFY**: Check Discord public channels for emails, license keys
2. 🗑️ **DELETE**: Remove messages with PII from Discord channel
3. 🔧 **FIX**: Split notification function (public + private)
4. ✅ **TEST**: Verify PII only goes to private admin channels
5. 📝 **AUDIT**: Review all notification functions for privacy compliance

**Rate Limiting (429 Errors)**:

1. ⚠️ **IDENTIFY**: Check which webhook is being rate limited
2. ⏸️ **PAUSE**: Stop sending requests to that webhook
3. 🔧 **IMPLEMENT**: Add rate limiter (25 requests/60 seconds conservative)
4. ✅ **TEST**: Verify rate limiter prevents 429 errors
5. 📊 **MONITOR**: Track webhook usage and adjust limits

## 📖 External Resources

**Discord Documentation**:

- [Webhooks Guide](https://discord.com/developers/docs/resources/webhook)
- [Webhook Execution](https://discord.com/developers/docs/resources/webhook#execute-webhook)
- [Embed Structure](https://discord.com/developers/docs/resources/channel#embed-object)
- [Rate Limits](https://discord.com/developers/docs/topics/rate-limits)

**Community Resources**:

- [Discord Webhook Tester](https://discohook.org/)
- [Embed Builder](https://autocode.com/tools/discord/embed-builder/)
- [Color Picker](https://htmlcolorcodes.com/)

**HiveTechs Documentation**:

- Main Architecture: `/ARCHITECTURE.md`
- Deployment Guide: `/DEPLOYMENT_READY.md`
- Project README: `/README.md`

## 📊 Integration Status

**Current Version**: v1.0 **Implementation Status**: ✅ Production-ready
**Security Status**: ⚠️ Webhook URL exposed on line 10 (requires rotation)
**Privacy Compliance**: ✅ Fixed (commit d277df9)

**Notification Functions Implemented**: 8

- `sendDiscordMessage()` - Core webhook sender
- `notifyNewUserPublic()` - Public celebration (no PII)
- `notifyNewUserPrivate()` - Admin logs (with PII)
- `notifyNewUser()` - Combined (both channels)
- `notifySubscriptionChange()` - Subscription updates
- `sendDailyAnalytics()` - Metrics dashboard
- `notifySystemStatus()` - System alerts
- `announceNewFeature()` - Feature announcements

**Testing Coverage**: ✅ Comprehensive

- Manual testing via `/api/discord/test`
- Automated signup flow testing
- Privacy compliance verified
- Rate limiting tested

---

**Last Updated**: 2025-10-12 **Maintained By**: discord-expert agent **Next
Review**: When adding new notification functions or channels
