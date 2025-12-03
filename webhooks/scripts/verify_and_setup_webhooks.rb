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

# Required PCO webhook events - ALL available events EXCEPT giving
# Total: 81 events (calendar: 4, groups: 9, people: 45, publishing: 6, services: 17)
REQUIRED_PCO_EVENTS = [
  # Calendar (4)
  "calendar.v2.events.event_request.approved",
  "calendar.v2.events.event_request.created",
  "calendar.v2.events.event_request.destroyed",
  "calendar.v2.events.event_request.updated",
  # Groups (9)
  "groups.church_center.v2.events.group_application.created",
  "groups.church_center.v2.events.group_application.destroyed",
  "groups.church_center.v2.events.group_application.updated",
  "groups.v2.events.group.created",
  "groups.v2.events.group.destroyed",
  "groups.v2.events.group.updated",
  "groups.v2.events.membership.created",
  "groups.v2.events.membership.destroyed",
  "groups.v2.events.membership.updated",
  # People (45)
  "people.v2.events.address.created",
  "people.v2.events.address.destroyed",
  "people.v2.events.address.updated",
  "people.v2.events.email.created",
  "people.v2.events.email.destroyed",
  "people.v2.events.email.updated",
  "people.v2.events.field_datum.created",
  "people.v2.events.field_datum.destroyed",
  "people.v2.events.field_datum.updated",
  "people.v2.events.field_definition.created",
  "people.v2.events.field_definition.destroyed",
  "people.v2.events.field_definition.updated",
  "people.v2.events.form_submission.created",
  "people.v2.events.household.created",
  "people.v2.events.household.destroyed",
  "people.v2.events.household.updated",
  "people.v2.events.list.created",
  "people.v2.events.list.destroyed",
  "people.v2.events.list.refreshed",
  "people.v2.events.list_result.created",
  "people.v2.events.list_result.destroyed",
  "people.v2.events.note.created",
  "people.v2.events.note.destroyed",
  "people.v2.events.person.created",
  "people.v2.events.person.destroyed",
  "people.v2.events.person.updated",
  "people.v2.events.person_merger.created",
  "people.v2.events.phone_number.created",
  "people.v2.events.phone_number.destroyed",
  "people.v2.events.phone_number.updated",
  "people.v2.events.workflow.created",
  "people.v2.events.workflow.destroyed",
  "people.v2.events.workflow.updated",
  "people.v2.events.workflow_card.created",
  "people.v2.events.workflow_card.destroyed",
  "people.v2.events.workflow_card.updated",
  "people.v2.events.workflow_card_activity.created",
  "people.v2.events.workflow_card_activity.destroyed",
  "people.v2.events.workflow_card_activity.updated",
  "people.v2.events.workflow_share.created",
  "people.v2.events.workflow_share.destroyed",
  "people.v2.events.workflow_share.updated",
  "people.v2.events.workflow_step.created",
  "people.v2.events.workflow_step.destroyed",
  "people.v2.events.workflow_step.updated",
  # Publishing (6)
  "publishing.v2.events.episode.created",
  "publishing.v2.events.episode.destroyed",
  "publishing.v2.events.episode.updated",
  "publishing.v2.events.episode_time.created",
  "publishing.v2.events.episode_time.destroyed",
  "publishing.v2.events.episode_time.updated",
  # Services (17)
  "services.v2.events.arrangement.created",
  "services.v2.events.arrangement.destroyed",
  "services.v2.events.arrangement.updated",
  "services.v2.events.key.created",
  "services.v2.events.key.destroyed",
  "services.v2.events.key.updated",
  "services.v2.events.plan.created",
  "services.v2.events.plan.destroyed",
  "services.v2.events.plan.live.updated",
  "services.v2.events.plan.updated",
  "services.v2.events.plan_item.created",
  "services.v2.events.plan_item.destroyed",
  "services.v2.events.plan_note.created",
  "services.v2.events.plan_note.destroyed",
  "services.v2.events.plan_note.updated",
  "services.v2.events.song.created",
  "services.v2.events.song.updated",
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
