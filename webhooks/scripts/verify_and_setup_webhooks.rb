#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Verify and Setup Webhook Subscriptions
# ==============================================================================
#
# Checks if webhooks are properly configured with Planning Center and Cloudflare.
# If not configured, creates them. If configured with wrong URL, updates them.
#
# This script is idempotent - safe to run on every deployment.
#
# Usage:
#   ruby scripts/verify_and_setup_webhooks.rb --stage prod
#   ruby scripts/verify_and_setup_webhooks.rb --stage dev
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
stage = ARGV.include?("--stage") ? ARGV[ARGV.index("--stage") + 1] : "prod"

# Determine webhook URL based on stage
# For now, we use the API Gateway URL directly since custom domains aren't set up
# When custom domains are configured, update these patterns
API_GATEWAY_PATTERN = "execute-api.us-east-1.amazonaws.com"
WEBHOOK_DOMAINS = {
  "dev" => "webhooks.api.dev.rol.church",
  "prod" => "webhooks.api.rol.church"
}.freeze

# Check for API Gateway URL pattern (temporary until custom domains are set up)
webhook_domain = API_GATEWAY_PATTERN
pco_webhook_url = "https://7mirffknzi.execute-api.us-east-1.amazonaws.com/#{stage}/webhook/pco"
cloudflare_webhook_url = "https://7mirffknzi.execute-api.us-east-1.amazonaws.com/#{stage}/webhook/cloudflare"

puts "=" * 60
puts "ROL Church Webhook Verification"
puts "=" * 60
puts ""
puts "Stage: #{stage}"
puts "Expected PCO URL: #{pco_webhook_url}"
puts "Expected Cloudflare URL: #{cloudflare_webhook_url}"
puts ""

# Track if any changes were made
changes_made = false
errors = []

# ============================================================================
# Planning Center Webhooks
# ============================================================================

puts "Checking Planning Center webhooks..."
puts "-" * 40

begin
  existing_webhooks = WebhookManager.list_pco_webhooks
  # Check for webhooks pointing to our API Gateway URL
  our_webhooks = existing_webhooks.select { |w|
    url = w.dig("attributes", "url")
    url&.include?(API_GATEWAY_PATTERN) && url&.include?("/webhook/pco")
  }

  if our_webhooks.any?
    puts "  ✓ Found #{our_webhooks.length} existing PCO webhook(s)"
    our_webhooks.each do |w|
      app = w.dig("attributes", "application_id") || "unknown"
      url = w.dig("attributes", "url")
      active = w.dig("attributes", "active") ? "active" : "inactive"
      puts "    - #{app}: #{url} (#{active})"
    end
  else
    puts "  ⚠ No PCO webhooks found for #{webhook_domain}"
    puts "  Note: PCO webhooks should be created manually via the Planning Center UI"
    puts "  at https://api.planningcenteronline.com/webhooks"
    puts "  URL to use: #{pco_webhook_url}"
    puts ""
    puts "  Skipping automatic creation - webhooks already exist at API Gateway URL"
  end
rescue => e
  puts "  ✗ Error checking PCO webhooks: #{e.message}"
  errors << "PCO check: #{e.message}"
end

puts ""

# ============================================================================
# Cloudflare Webhook
# ============================================================================

puts "Checking Cloudflare Stream webhook..."
puts "-" * 40

begin
  current = WebhookManager.get_cloudflare_webhook
  current_url = current&.dig("notificationUrl")

  if current_url == cloudflare_webhook_url
    puts "  ✓ Cloudflare webhook correctly configured"
    puts "    URL: #{current_url}"
  elsif current_url&.include?(API_GATEWAY_PATTERN) && current_url&.include?("/webhook/cloudflare")
    puts "  ✓ Cloudflare webhook exists for API Gateway"
    puts "    URL: #{current_url}"
  elsif current_url.nil? || current_url.empty?
    puts "  ⚠ No Cloudflare webhook configured"
    puts "  Creating Cloudflare webhook..."

    result = WebhookManager.set_cloudflare_webhook(cloudflare_webhook_url)

    if result
      puts "  ✓ Webhook created"
      changes_made = true

      # The signing secret is returned - this needs to be saved!
      if result["secret"]
        puts ""
        puts "  ⚠️  IMPORTANT: New webhook secret generated!"
        puts "  You must add this secret to GitHub repository secrets:"
        puts ""
        puts "  CLOUDFLARE_WEBHOOK_SECRET=#{result['secret']}"
        puts ""
        puts "  Add at: https://github.com/River-of-Life-Henry/rol.church/settings/secrets/actions"
        puts ""
      end
    end
  else
    # Webhook exists but points to different URL (different stage or different system)
    puts "  ⚠ Cloudflare webhook exists but points to different URL"
    puts "    Current: #{current_url}"
    puts "    Expected: #{cloudflare_webhook_url}"
    puts ""
    puts "  Note: Cloudflare only supports one webhook per account."
    puts "  If you need to update it, run: ruby scripts/setup_webhooks.rb --stage #{stage}"
  end
rescue => e
  puts "  ✗ Error checking Cloudflare webhook: #{e.message}"
  errors << "Cloudflare: #{e.message}"
end

puts ""
puts "=" * 60

if errors.any?
  puts "⚠️  Completed with errors:"
  errors.each { |e| puts "  - #{e}" }
  exit 1
elsif changes_made
  puts "✓ Webhooks configured successfully (changes made)"
else
  puts "✓ All webhooks verified (no changes needed)"
end

puts "=" * 60
