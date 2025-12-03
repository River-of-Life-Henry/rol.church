# ROL Church Webhooks

AWS Lambda function that receives webhooks from Planning Center and Cloudflare, then triggers the GitHub Actions sync workflow.

## Architecture

```
Planning Center ──┐
                  ├──▶ API Gateway ──▶ Lambda ──▶ GitHub Actions (workflow_dispatch)
Cloudflare Stream ┘                                     │
                                                        ▼
                                              daily-sync.yml
                                                        │
                                                        ▼
                                              deploy.yml (build & deploy)
```

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/webhook/pco` | POST | Receives Planning Center webhooks |
| `/webhook/cloudflare` | POST | Receives Cloudflare Stream webhooks |
| `/health` | GET | Health check endpoint |

## Domains

| Stage | Domain |
|-------|--------|
| dev | `webhooks.api.dev.rol.church` |
| prod | `webhooks.api.rol.church` |

## How It Works

1. **Planning Center** or **Cloudflare** sends a webhook when data changes
2. **Lambda** verifies the webhook signature (HMAC-SHA256)
3. **Lambda** triggers the GitHub Actions `daily-sync.yml` workflow with:
   - `sync_source: pco` - runs all Planning Center syncs
   - `sync_source: cloudflare` - runs only Cloudflare video sync
4. **GitHub Actions** runs the appropriate sync scripts
5. If changes are detected, the deploy workflow is triggered

## Concurrency Control

GitHub Actions is configured with `cancel-in-progress: true`:
- If multiple webhooks fire while a sync is running, queued runs are cancelled
- Only the latest triggered run will execute after the current one completes
- Running jobs are never killed mid-execution

Example: If 5 webhooks fire while job #1 is running:
- Jobs #2, #3, #4 are cancelled (skipped)
- Job #5 runs after #1 completes

## Prerequisites

1. **Node.js** (for Serverless Framework)
2. **Serverless Framework v3+**
3. **Ruby 3.2** (for setup/teardown scripts)
4. **AWS CLI** configured with credentials

```bash
npm install -g serverless
npm install -g serverless-domain-manager
```

## Deployment

### 1. Set up environment variables

Copy `.env.example` to `.env` and fill in the values:

```bash
cp .env.example .env
```

### 2. Deploy to AWS

```bash
# Deploy to dev
sls deploy --stage dev

# Deploy to prod
sls deploy --stage prod
```

### 3. Set up custom domain (first time only)

```bash
# Create the custom domain
sls create_domain --stage prod

# Then deploy again
sls deploy --stage prod
```

### 4. Register webhooks with PCO and Cloudflare

```bash
# Load environment variables
source .env

# Register webhooks for prod
bundle exec ruby scripts/setup_webhooks.rb --stage prod
```

**Important:** Save the Cloudflare webhook secret returned by the setup script!

### 5. Update Lambda environment

After getting the Cloudflare webhook secret, update the Lambda environment:

```bash
# Option 1: Use AWS Console
# Lambda > Functions > rol-webhooks-prod-webhook > Configuration > Environment variables

# Option 2: Redeploy with updated .env
sls deploy --stage prod
```

## Testing

### Test health endpoint

```bash
curl https://webhooks.api.rol.church/health
```

### Test webhook (manual)

```bash
# Note: This will fail signature verification unless you compute a valid HMAC
curl -X POST https://webhooks.api.rol.church/webhook/pco \
  -H "Content-Type: application/json" \
  -H "x-pco-signature: your_signature_here" \
  -d '{"test": true}'
```

## Removing Webhooks

To remove webhook subscriptions before deleting the Lambda:

```bash
# Remove webhooks for a specific stage
bundle exec ruby scripts/teardown_webhooks.rb --stage prod

# Remove webhooks for all stages
bundle exec ruby scripts/teardown_webhooks.rb --all
```

## Removing the Lambda

```bash
# Remove Lambda and API Gateway
sls remove --stage prod

# Remove custom domain (optional)
sls delete_domain --stage prod
```

## Environment Variables

| Variable | Description | Where |
|----------|-------------|-------|
| `GITHUB_PAT` | GitHub PAT with Actions write | Lambda |
| `GITHUB_REPO` | Repository (owner/repo) | Lambda |
| `PCO_WEBHOOK_SECRET` | Secret for PCO signature verification | Lambda |
| `CLOUDFLARE_WEBHOOK_SECRET` | Secret for CF signature verification | Lambda |
| `ROL_PLANNING_CENTER_CLIENT_ID` | PCO API credentials | Setup scripts |
| `ROL_PLANNING_CENTER_SECRET` | PCO API credentials | Setup scripts |
| `CLOUDFLARE_ACCOUNT_ID` | CF account ID | Setup scripts |
| `CLOUDFLARE_API_TOKEN` | CF API token (Stream Write) | Setup scripts |

## Files

```
webhooks/
├── serverless.yml           # Serverless Framework config
├── Gemfile                  # Ruby dependencies (for scripts)
├── handler.rb               # Main Lambda handler
├── lib/
│   ├── webhook_verifier.rb  # Signature verification
│   ├── github_trigger.rb    # GitHub Actions API client
│   └── webhook_manager.rb   # PCO/CF webhook management
├── scripts/
│   ├── setup_webhooks.rb    # Register webhooks
│   └── teardown_webhooks.rb # Remove webhooks
├── .env.example             # Example environment file
└── README.md                # This file
```

## Troubleshooting

### Webhook signature verification failed

- Check that the webhook secret in Lambda matches what was configured in PCO/Cloudflare
- Ensure the raw request body is being used for verification (not parsed JSON)
- Check CloudWatch logs for detailed error messages

### GitHub Actions not triggering

- Verify the `GITHUB_PAT` has `actions:write` permission
- Check that the token hasn't expired
- Verify the repository name is correct (owner/repo format)

### Webhooks not being received

- Check the Lambda function logs in CloudWatch
- Verify the domain is correctly configured in Route53
- Test the health endpoint to confirm the Lambda is running
