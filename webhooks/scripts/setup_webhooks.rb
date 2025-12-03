#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Setup Webhook Subscriptions
# ==============================================================================
#
# Registers webhook endpoints with Planning Center and Cloudflare.
# Run this after deploying the Lambda function to register the webhook URLs.
#
# Usage:
#   ruby scripts/setup_webhooks.rb --stage prod
#   ruby scripts/setup_webhooks.rb --stage dev
#
# Environment Variables Required:
#   ROL_PLANNING_CENTER_CLIENT_ID  - PCO API credentials
#   ROL_PLANNING_CENTER_SECRET     - PCO API credentials
#   CLOUDFLARE_ACCOUNT_ID          - Cloudflare account ID
#   CLOUDFLARE_API_TOKEN           - Cloudflare API token with Stream Write
#
# ==============================================================================

require_relative "../lib/webhook_manager"

# Parse command line arguments
stage = ARGV.include?("--stage") ? ARGV[ARGV.index("--stage") + 1] : "dev"
dry_run = ARGV.include?("--dry-run")

# Determine webhook URL based on stage
WEBHOOK_DOMAINS = {
  "dev" => "webhooks.api.dev.rol.church",
  "prod" => "webhooks.api.rol.church"
}.freeze

webhook_domain = WEBHOOK_DOMAINS[stage] || WEBHOOK_DOMAINS["dev"]
pco_webhook_url = "https://#{webhook_domain}/webhook/pco"
cloudflare_webhook_url = "https://#{webhook_domain}/webhook/cloudflare"

puts "=" * 60
puts "ROL Church Webhook Setup"
puts "=" * 60
puts ""
puts "Stage: #{stage}"
puts "PCO Webhook URL: #{pco_webhook_url}"
puts "Cloudflare Webhook URL: #{cloudflare_webhook_url}"
puts ""

if dry_run
  puts "[DRY RUN] Would register webhooks with the above URLs"
  exit 0
end

# Validate environment
%w[
  ROL_PLANNING_CENTER_CLIENT_ID
  ROL_PLANNING_CENTER_SECRET
  CLOUDFLARE_ACCOUNT_ID
  CLOUDFLARE_API_TOKEN
].each do |var|
  unless ENV[var]
    puts "ERROR: Missing required environment variable: #{var}"
    exit 1
  end
end

# ============================================================================
# Planning Center Webhooks
# ============================================================================

puts "Setting up Planning Center webhooks..."
puts "-" * 40

# PCO applications and their webhook-enabled events
# Note: Not all PCO apps support webhooks yet
PCO_APPS = {
  "people" => "People (contacts, members)",
  "calendar" => "Calendar (events, instances)",
  # "groups" => "Groups (group events, membership)",  # Check if supported
  # "services" => "Services (plans, songs, media)"    # Check if supported
}.freeze

PCO_APPS.each do |app_id, description|
  begin
    puts "  Creating webhook for #{description}..."

    result = WebhookManager.create_pco_webhook(
      name: "ROL Church Website Sync (#{stage})",
      url: pco_webhook_url,
      application: app_id
    )

    if result
      puts "    ✓ Created subscription ID: #{result['id']}"
    end
  rescue => e
    puts "    ✗ Error: #{e.message}"
  end
end

puts ""

# ============================================================================
# Cloudflare Webhook
# ============================================================================

puts "Setting up Cloudflare Stream webhook..."
puts "-" * 40

begin
  result = WebhookManager.set_cloudflare_webhook(cloudflare_webhook_url)

  if result
    puts "  ✓ Webhook registered"

    # The signing secret is returned - save this!
    if result["secret"]
      puts ""
      puts "  IMPORTANT: Save this webhook signing secret!"
      puts "  CLOUDFLARE_WEBHOOK_SECRET=#{result['secret']}"
      puts ""
      puts "  Add this to your Lambda environment variables."
    end
  end
rescue => e
  puts "  ✗ Error: #{e.message}"
end

puts ""
puts "=" * 60
puts "Setup complete!"
puts ""
puts "Next steps:"
puts "1. Save the Cloudflare webhook secret above"
puts "2. Update Lambda environment variables with the secret"
puts "3. Test by making a change in Planning Center or uploading a video"
puts "=" * 60
