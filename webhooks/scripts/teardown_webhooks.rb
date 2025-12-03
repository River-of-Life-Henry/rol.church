#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Teardown Webhook Subscriptions
# ==============================================================================
#
# Removes webhook subscriptions from Planning Center and Cloudflare.
# Run this before deleting the Lambda function or changing environments.
#
# Usage:
#   ruby scripts/teardown_webhooks.rb --stage prod
#   ruby scripts/teardown_webhooks.rb --stage dev
#   ruby scripts/teardown_webhooks.rb --all  # Remove from both stages
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
stage = ARGV.include?("--stage") ? ARGV[ARGV.index("--stage") + 1] : nil
all_stages = ARGV.include?("--all")
dry_run = ARGV.include?("--dry-run")

unless stage || all_stages
  puts "Usage: ruby scripts/teardown_webhooks.rb --stage <dev|prod>"
  puts "       ruby scripts/teardown_webhooks.rb --all"
  puts ""
  puts "Options:"
  puts "  --stage <stage>  Remove webhooks for specific stage"
  puts "  --all            Remove webhooks for all stages"
  puts "  --dry-run        Show what would be deleted without deleting"
  exit 1
end

# Determine which domains to remove
WEBHOOK_DOMAINS = {
  "dev" => "webhooks.api.dev.rol.church",
  "prod" => "webhooks.api.rol.church"
}.freeze

domains_to_remove = if all_stages
                      WEBHOOK_DOMAINS.values
                    else
                      [WEBHOOK_DOMAINS[stage]].compact
                    end

if domains_to_remove.empty?
  puts "ERROR: Invalid stage '#{stage}'. Use 'dev' or 'prod'."
  exit 1
end

puts "=" * 60
puts "ROL Church Webhook Teardown"
puts "=" * 60
puts ""
puts "Removing webhooks for: #{domains_to_remove.join(', ')}"
puts ""

if dry_run
  puts "[DRY RUN] Would remove webhooks matching the above domains"
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

puts "Removing Planning Center webhooks..."
puts "-" * 40

domains_to_remove.each do |domain|
  begin
    count = WebhookManager.delete_pco_webhooks_matching(domain)
    puts "  ✓ Removed #{count} webhook(s) matching #{domain}"
  rescue => e
    puts "  ✗ Error: #{e.message}"
  end
end

puts ""

# ============================================================================
# Cloudflare Webhook
# ============================================================================

puts "Removing Cloudflare Stream webhook..."
puts "-" * 40

begin
  # Check current webhook
  current = WebhookManager.get_cloudflare_webhook
  current_url = current&.dig("notificationUrl") || ""

  # Only remove if URL matches one of our domains
  if domains_to_remove.any? { |d| current_url.include?(d) }
    WebhookManager.delete_cloudflare_webhook
    puts "  ✓ Removed Cloudflare webhook: #{current_url}"
  else
    puts "  - Cloudflare webhook URL doesn't match our domains, skipping"
    puts "    Current URL: #{current_url}"
  end
rescue => e
  puts "  ✗ Error: #{e.message}"
end

puts ""
puts "=" * 60
puts "Teardown complete!"
puts "=" * 60
