#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Verify and Setup Webhook Subscriptions
# ==============================================================================
#
# Checks if webhooks are properly configured with Planning Center and Cloudflare.
# Verifies exact number and type of webhooks - no more, no less.
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

# API Gateway URL pattern
API_GATEWAY_PATTERN = "execute-api.us-east-1.amazonaws.com"
API_GATEWAY_ID = "7mirffknzi"

# Expected webhook URLs
pco_webhook_url = "https://#{API_GATEWAY_ID}.#{API_GATEWAY_PATTERN}/#{stage}/webhook/pco"
cloudflare_webhook_url = "https://#{API_GATEWAY_ID}.#{API_GATEWAY_PATTERN}/#{stage}/webhook/cloudflare"

# Required PCO webhook events - exactly these, no more, no less
REQUIRED_PCO_EVENTS = [
  "groups.v2.events.group.created",
  "groups.v2.events.group.updated",
  "groups.v2.events.group.destroyed",
  "calendar.v2.events.event_request.approved",
  "calendar.v2.events.event_request.updated",
  "people.v2.events.person.created",
  "people.v2.events.person.updated",
].freeze

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

  # Filter to webhooks pointing to our API Gateway URL
  our_webhooks = existing_webhooks.select { |w|
    url = w.dig("attributes", "url")
    url&.include?(API_GATEWAY_ID) && url&.include?("/webhook/pco")
  }

  # Get event names from our webhooks
  our_event_names = our_webhooks.map { |w| w.dig("attributes", "name") }.sort
  required_events_sorted = REQUIRED_PCO_EVENTS.sort

  # Check for exact match
  missing_events = required_events_sorted - our_event_names
  extra_events = our_event_names - required_events_sorted

  if missing_events.empty? && extra_events.empty?
    puts "  ✓ PCO webhooks correctly configured (#{our_webhooks.length} webhooks)"
    our_webhooks.each do |w|
      name = w.dig("attributes", "name")
      active = w.dig("attributes", "active") ? "active" : "inactive"
      puts "    - #{name} (#{active})"
    end
  else
    if missing_events.any?
      puts "  ⚠ Missing PCO webhook events:"
      missing_events.each { |e| puts "    - #{e}" }

      # Create missing webhooks
      puts ""
      puts "  Creating missing webhooks..."
      missing_events.each do |event_name|
        begin
          result = WebhookManager.create_pco_webhook(name: event_name, url: pco_webhook_url)
          if result
            puts "    ✓ Created: #{event_name}"
            changes_made = true
          end
        rescue => e
          puts "    ✗ Failed to create #{event_name}: #{e.message}"
          errors << "PCO create #{event_name}: #{e.message}"
        end
      end
    end

    if extra_events.any?
      puts "  ⚠ Extra PCO webhook events (will delete):"
      extra_events.each { |e| puts "    - #{e}" }

      # Delete extra webhooks
      puts ""
      puts "  Deleting extra webhooks..."
      our_webhooks.each do |w|
        name = w.dig("attributes", "name")
        if extra_events.include?(name)
          begin
            WebhookManager.delete_pco_webhook(w["id"])
            puts "    ✓ Deleted: #{name}"
            changes_made = true
          rescue => e
            puts "    ✗ Failed to delete #{name}: #{e.message}"
            errors << "PCO delete #{name}: #{e.message}"
          end
        end
      end
    end
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
  elsif current_url.nil? || current_url.empty?
    puts "  ⚠ No Cloudflare webhook configured"
    puts "  Creating Cloudflare webhook..."

    result = WebhookManager.set_cloudflare_webhook(cloudflare_webhook_url)

    if result
      puts "  ✓ Webhook created"
      puts "    URL: #{cloudflare_webhook_url}"
      changes_made = true

      # The signing secret is returned - output for GitHub Actions to capture
      if result["secret"]
        puts ""
        puts "  CLOUDFLARE_WEBHOOK_SECRET=#{result['secret']}"
        puts ""
      end
    end
  elsif current_url != cloudflare_webhook_url
    # Webhook exists but points to different URL - update it
    puts "  ⚠ Cloudflare webhook URL mismatch"
    puts "    Current:  #{current_url}"
    puts "    Expected: #{cloudflare_webhook_url}"
    puts ""
    puts "  Updating Cloudflare webhook..."

    result = WebhookManager.set_cloudflare_webhook(cloudflare_webhook_url)

    if result
      puts "  ✓ Webhook updated"
      puts "    URL: #{cloudflare_webhook_url}"
      changes_made = true

      if result["secret"]
        puts ""
        puts "  CLOUDFLARE_WEBHOOK_SECRET=#{result['secret']}"
        puts ""
      end
    end
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
