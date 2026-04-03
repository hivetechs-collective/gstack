# Paddle Expert Knowledge Base

**Comprehensive documentation for Paddle.com billing integration**

This knowledge base provides everything needed to integrate, configure, and
maintain Paddle billing in your Next.js + Cloudflare Workers application.

---

## Quick Navigation

### 🚀 Getting Started

**New to Paddle?** Start here:

1. Read [Quick Reference](./quick-reference.md) for common tasks
2. Follow [Setup Checklist](./paddle-setup-checklist.md) step-by-step
3. Configure environment using [Configuration Guide](./configuration-guide.md)

**Already integrated?** Use the quick reference for common operations.

### 📚 Documentation Index

#### Configuration & Setup

| Document                                                           | Purpose                                 | Audience           |
| ------------------------------------------------------------------ | --------------------------------------- | ------------------ |
| [Configuration Guide](./configuration-guide.md)                    | Complete Paddle setup and configuration | Developers, DevOps |
| [Setup Checklist](./paddle-setup-checklist.md)                     | Step-by-step integration checklist      | Developers         |
| [`.env.paddle.example`](../../../../.env.paddle.example)           | Environment variable template           | All team members   |
| [Validation Script](../../../../scripts/validate-paddle-config.sh) | Automated configuration validation      | Developers, CI/CD  |

#### Integration Documentation

| Document                                                   | Purpose                             | Audience            |
| ---------------------------------------------------------- | ----------------------------------- | ------------------- |
| [Quick Reference](./quick-reference.md)                    | Common operations and code snippets | Developers          |
| [HiveTechs Integration](./hivetechs-paddle-integration.md) | Complete reference implementation   | Developers          |
| [Troubleshooting Guide](./troubleshooting-guide.md)        | Problem resolution and debugging    | Developers, Support |

#### API & Webhooks

| Section                | Location                                                                            | Purpose                     |
| ---------------------- | ----------------------------------------------------------------------------------- | --------------------------- |
| Webhook Events         | [Quick Reference - Webhooks](./quick-reference.md#webhook-events)                   | Event types and handling    |
| API Methods            | [Quick Reference - API](./quick-reference.md#paddle-api-methods)                    | Subscription management API |
| Signature Verification | [Configuration Guide - Webhooks](./configuration-guide.md#step-5-configure-webhook) | Security implementation     |

---

## Common Tasks

### Configuration

**Set up Paddle for the first time:**

```bash
# 1. Copy environment template
cp .env.paddle.example .env.local

# 2. Fill in your Paddle credentials
# Edit .env.local with your Paddle Dashboard values

# 3. Validate configuration
scripts/validate-paddle-config.sh

# 4. Start development
npm run dev
```

**Validate existing configuration:**

```bash
scripts/validate-paddle-config.sh
```

**Deploy to Cloudflare Workers:**

```bash
# Set secrets
wrangler secret put PADDLE_WEBHOOK_SECRET
wrangler secret put PADDLE_PRODUCTION_API_KEY

# Deploy
wrangler deploy
```

### Testing

**Test webhook endpoint (should return 401):**

```bash
curl -X POST http://localhost:3001/api/paddle/webhook \
  -H "Content-Type: application/json" \
  -d '{"event_type":"test","data":{}}'
```

**Test checkout flow (sandbox):**

- Use Paddle test card: 4242 4242 4242 4242
- Expiry: Any future date (e.g., 12/25)
- CVC: Any 3 digits (e.g., 123)

### Monitoring

**View webhook logs:**

```bash
# Cloudflare Workers logs
wrangler tail | grep -i paddle

# Paddle Dashboard
# Navigate to: Developer Tools → Events
```

**Check subscription status:**

```bash
# Check database
wrangler d1 execute your-db --command \
  "SELECT email, subscription_status, paddle_subscription_id FROM users WHERE email='user@example.com'"
```

---

## Environment Variables Reference

### Required Variables

| Variable                          | Type   | Description                    | Example          |
| --------------------------------- | ------ | ------------------------------ | ---------------- |
| `PADDLE_VENDOR_ID`                | Public | Your Paddle account ID         | `232110`         |
| `PADDLE_WEBHOOK_SECRET`           | SECRET | Webhook signature verification | `pdl_ntfset_...` |
| `NEXT_PUBLIC_PADDLE_VENDOR_ID`    | Public | Vendor ID for frontend         | `232110`         |
| `NEXT_PUBLIC_PADDLE_ENVIRONMENT`  | Public | Sandbox or production          | `sandbox`        |
| `NEXT_PUBLIC_PADDLE_CLIENT_TOKEN` | Public | Frontend Paddle.js token       | `test_abc123...` |

**API Keys (choose one pattern):**

- Single key: `PADDLE_API_KEY`
- Separate keys: `PADDLE_SANDBOX_API_KEY` + `PADDLE_PRODUCTION_API_KEY`

**Webhook IDs (choose one pattern):**

- Single ID: `PADDLE_WEBHOOK_ID`
- Separate IDs: `PADDLE_WEBHOOK_ID_SANDBOX` + `PADDLE_WEBHOOK_ID_PRODUCTION`

### Optional Variables

| Variable                   | Type   | Description                          |
| -------------------------- | ------ | ------------------------------------ |
| `PADDLE_PRICE_BASIC`       | Public | Basic subscription plan price ID     |
| `PADDLE_PRICE_STANDARD`    | Public | Standard subscription plan price ID  |
| `PADDLE_PRICE_PREMIUM`     | Public | Premium subscription plan price ID   |
| `PADDLE_PRICE_UNLIMITED`   | Public | Unlimited subscription plan price ID |
| `PADDLE_PRICE_TEAM`        | Public | Team subscription plan price ID      |
| `PADDLE_PRICE_CREDITS_25`  | Public | 25 credits one-time purchase         |
| `PADDLE_PRICE_CREDITS_75`  | Public | 75 credits one-time purchase         |
| `PADDLE_PRICE_CREDITS_200` | Public | 200 credits one-time purchase        |

See [`.env.paddle.example`](../../../../.env.paddle.example) for complete
documentation.

---

## Paddle Dashboard Locations

**Quick navigation to key Paddle Dashboard sections:**

### Authentication

- **Path**: Developer Tools → Authentication
- **Purpose**: Get Vendor ID, API keys, client tokens
- **Required for**: Initial setup, API integration

### Products & Pricing

- **Path**: Catalog → Products
- **Purpose**: Create products and prices
- **Required for**: Checkout integration

### Webhooks

- **Path**: Developer Tools → Notifications
- **Purpose**: Configure webhook endpoints
- **Required for**: Event handling, subscription updates

### Event Logs

- **Path**: Developer Tools → Events
- **Purpose**: View webhook delivery logs
- **Use for**: Debugging, monitoring

### Transactions

- **Path**: Transactions
- **Purpose**: View all payments and transactions
- **Use for**: Revenue tracking, debugging payments

### Subscriptions

- **Path**: Subscriptions
- **Purpose**: View and manage all subscriptions
- **Use for**: Customer support, subscription debugging

---

## Security Best Practices

### Secrets Management

**CRITICAL RULES:**

- ❌ **NEVER** commit secrets to git
- ❌ **NEVER** expose `PADDLE_WEBHOOK_SECRET` in frontend
- ❌ **NEVER** log API keys or webhook secrets
- ✅ **ALWAYS** use Cloudflare secrets for production (`wrangler secret put`)
- ✅ **ALWAYS** verify webhook signatures
- ✅ **ALWAYS** use HTTPS for webhook endpoints

### Environment Separation

**Best practices:**

- Use separate Paddle accounts for sandbox and production
- Use different API keys for sandbox and production
- Test in sandbox before deploying to production
- Never use production credentials in development

### Webhook Security

**Required security measures:**

1. Verify signature on EVERY webhook request (401 if invalid)
2. Use HTTPS only (Paddle won't deliver to HTTP)
3. Respond within 10 seconds
4. Implement rate limiting on webhook endpoint
5. Log all webhook attempts (success and failure)

---

## Troubleshooting

### Quick Diagnostics

**Configuration issues:**

```bash
# Run validation script
scripts/validate-paddle-config.sh

# Check for common misconfigurations
```

**Webhook issues:**

```bash
# Test webhook signature verification
curl -X POST https://yourdomain.com/api/paddle/webhook -d '{"test":"data"}'
# Expected: 401 Unauthorized

# Check Cloudflare logs
wrangler tail | grep -i paddle

# Check Paddle Event logs
# Paddle Dashboard → Developer Tools → Events
```

**Checkout issues:**

```javascript
// In browser console, verify Paddle.js loaded
console.log(window.Paddle);
console.log(window.Paddle.Environment.get());
```

### Common Issues

| Symptom               | Likely Cause                             | Fix                                                            |
| --------------------- | ---------------------------------------- | -------------------------------------------------------------- |
| Webhook 401 errors    | Missing or wrong `PADDLE_WEBHOOK_SECRET` | Verify secret with `wrangler secret list`, re-set if needed    |
| Checkout not loading  | Wrong `NEXT_PUBLIC_PADDLE_CLIENT_TOKEN`  | Check token matches environment (test\_\* for sandbox)         |
| Wrong environment     | Sandbox/production mismatch              | Verify all env vars match (all sandbox or all production)      |
| Price not found       | Wrong Price ID for environment           | Use sandbox prices in sandbox, production prices in production |
| Webhook timeout       | Slow processing                          | Use Cloudflare Queues for async processing                     |
| Database not updating | Silent error in webhook handler          | Add comprehensive logging, check Cloudflare logs               |

See
[Configuration Guide - Troubleshooting](./configuration-guide.md#troubleshooting)
for detailed solutions.

---

## Integration Examples

### HiveTechs Website

**Reference implementation:**
[hivetechs-paddle-integration.md](./hivetechs-paddle-integration.md)

**Architecture:**

- Next.js 14 App Router
- Cloudflare Workers deployment
- D1 database for user/subscription data
- SMTP2GO for email notifications
- Paddle for billing and subscriptions

**Features implemented:**

- Subscription plans (Basic, Standard, Premium, Unlimited, Team)
- One-time credit packs (25, 75, 200 credits)
- Webhook event handling (subscription lifecycle)
- Subscription management portal
- Magic link authentication

**Key files:**

- Webhook handler: `src/app/api/paddle/webhook/route.ts`
- Paddle API client: `src/lib/paddle-api.ts`
- Checkout component: `src/components/CustomCheckout.tsx`
- Subscription management: `src/app/manage-subscription/`

---

## Development Workflow

### Initial Setup (One-time)

1. Create Paddle sandbox account
2. Configure products and prices in Paddle Dashboard
3. Copy `.env.paddle.example` to `.env.local`
4. Fill in Paddle credentials
5. Run validation script
6. Start development server

### Feature Development

1. Implement feature in local development
2. Test with Paddle sandbox
3. Verify webhook handling
4. Run validation script
5. Commit code changes
6. Deploy to staging (with sandbox credentials)
7. Test end-to-end in staging
8. Switch to production credentials
9. Deploy to production

### Testing Workflow

**Local development:**

```bash
# Start dev server
npm run dev

# Validate config
scripts/validate-paddle-config.sh

# Test webhook endpoint
curl -X POST http://localhost:3001/api/paddle/webhook -d '{"test":"data"}'
# Expected: 401 Unauthorized

# Test checkout
# Navigate to http://localhost:3001/checkout/basic
# Use test card: 4242 4242 4242 4242
```

**Staging/Production:**

```bash
# Deploy
wrangler deploy

# Test webhook
curl -X POST https://yourdomain.com/api/paddle/webhook -d '{"test":"data"}'
# Expected: 401 Unauthorized

# Monitor logs
wrangler tail | grep -i paddle

# Check Paddle Event logs
# Paddle Dashboard → Developer Tools → Events
```

---

## Maintenance

### Regular Tasks

**Daily:**

- Check Paddle Event logs for webhook failures
- Monitor Cloudflare logs for errors

**Weekly:**

- Review subscription metrics (Paddle Dashboard → Reports)
- Check for failed payments (Dashboard → Transactions)
- Verify database backups

**Monthly:**

- Review and rotate API keys (security best practice)
- Audit webhook event logs
- Update product pricing if needed
- Review customer support tickets related to payments

### Emergency Procedures

**Webhooks failing:**

```bash
# Check logs
wrangler tail | grep -i paddle

# Verify secret is set
wrangler secret list | grep PADDLE_WEBHOOK_SECRET

# Re-set if needed
wrangler secret put PADDLE_WEBHOOK_SECRET

# Rollback if necessary
wrangler rollback
```

**Checkout broken:**

```bash
# Disable checkout temporarily
# In wrangler.toml:
# NEXT_PUBLIC_ENABLE_CHECKOUT = "false"

# Deploy
wrangler deploy

# Fix issue, test, redeploy
# Re-enable checkout
```

---

## Support Resources

### Documentation

- **Paddle Developer Docs**: https://developer.paddle.com/
- **Paddle API Reference**: https://developer.paddle.com/api-reference/overview
- **Webhook Reference**: https://developer.paddle.com/webhooks/overview

### Community

- **Paddle Community**: https://paddle.community/
- **Paddle Support**: support@paddle.com
- **Cloudflare Discord**: https://discord.gg/cloudflaredev

### This Knowledge Base

- **Location**: `.claude/agents/research-planning/paddle-expert/knowledge/`
- **Maintainer**: paddle-expert agent
- **Last Updated**: 2025-10-09

---

## Version History

| Version | Date       | Changes                                                          |
| ------- | ---------- | ---------------------------------------------------------------- |
| 1.0.0   | 2025-10-09 | Initial knowledge base creation with comprehensive documentation |

---

## Contributing

To update this knowledge base:

1. Edit relevant documentation file
2. Update this README if adding new files
3. Test all code examples
4. Update version history
5. Commit with descriptive message

**File naming conventions:**

- Use kebab-case: `configuration-guide.md`
- Use descriptive names: `paddle-setup-checklist.md`
- Group by purpose: `quick-reference.md`, `troubleshooting-guide.md`

---

**Knowledge Base Maintainer:** paddle-expert agent **Repository:**
claude-pattern (template repository) **Related Projects:** hivetechs-website
(reference implementation)
