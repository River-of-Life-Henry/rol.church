#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Daily Sync Orchestrator
# ==============================================================================
#
# Purpose:
#   Master script that coordinates all data sync scripts for the ROL.Church
#   website. Runs scripts in parallel where possible, tracks changes, handles
#   errors, and sends detailed email reports.
#
# Usage:
#   ruby sync_all.rb
#   bundle exec ruby sync_all.rb
#
# How It Works:
#   1. Loads previous data files for comparison
#   2. Runs Group 1 scripts in parallel (independent scripts):
#      - sync_events.rb      (Planning Center Calendar)
#      - sync_groups.rb      (Planning Center Groups)
#      - sync_facebook_photos.rb (Facebook page photos)
#      - sync_team.rb        (Planning Center People)
#      - sync_cloudflare_video.rb (Cloudflare Stream)
#   3. Runs Group 2 scripts sequentially (dependent scripts):
#      - sync_hero_images.rb (depends on facebook_photos completing)
#   4. Compares old vs new data to generate changelog
#   5. Sends email report via AWS SES (if changes, errors, or alerts)
#
# Output:
#   - Console output with prefixed script names
#   - Email report with changes, errors, and alerts
#   - Exit code: 0 = success, 1 = errors occurred
#
# Email Report Contents:
#   - Script execution summary with durations
#   - Errors (if any)
#   - Alerts (action items from scripts)
#   - Changes by category (events, groups, hero images, team, video)
#
# Error Handling:
#   - Each script runs as subprocess (isolated failures)
#   - ERROR: prefix in output = captured and reported
#   - ALERT: prefix in output = captured for email (action needed)
#   - Non-zero exit codes = script failure
#
# Performance:
#   - Group 1: 5 scripts run in parallel
#   - Group 2: 1 script runs after Group 1
#   - Typical total runtime: 30-60 seconds
#
# Environment Variables (All):
#   ROL_PLANNING_CENTER_CLIENT_ID  - Planning Center API token
#   ROL_PLANNING_CENTER_SECRET     - Planning Center API secret
#   PCO_WEBSITE_HERO_MEDIA_ID      - PCO Media ID for hero images
#   CLOUDFLARE_API_TOKEN           - Cloudflare Stream API token
#   CLOUDFLARE_ACCOUNT_ID          - Cloudflare account ID
#   FB_PAGE_ID                     - Facebook page ID
#   FB_PAGE_ACCESS_TOKEN           - Facebook access token
#   AWS_ACCESS_KEY_ID              - AWS credentials (Rekognition + SES)
#   AWS_SECRET_ACCESS_KEY          - AWS credentials
#   AWS_REGION                     - AWS region (default: us-east-1)
#   SES_FROM_EMAIL                 - Email sender (must be SES verified)
#   CHANGELOG_EMAIL                - Email recipient (default: david.plappert@rol.church)
#
# ==============================================================================

require "bundler/setup"
require "json"
require "time"
require "parallel"
require "stringio"
require "open3"
require "bugsnag"

# Load environment variables from .env file (for local development only)
env_file = File.join(__dir__, ".env")
if File.exist?(env_file)
  begin
    require "dotenv"
    Dotenv.load(env_file)
  rescue LoadError
    # dotenv gem not available, skip loading .env file
  end
end

# Set timezone to Central Time
ENV['TZ'] = 'America/Chicago'

# Configure Bugsnag for error monitoring
Bugsnag.configure do |config|
  config.api_key = ENV["BUGSNAG_API_KEY"]
  config.app_version = "1.0.0"
  config.release_stage = ENV["GITHUB_ACTIONS"] ? "production" : "development"
  config.enabled_release_stages = %w[production development]
  config.app_type = "sync_script"
  config.project_root = File.dirname(__FILE__)
end

# Force immediate output
$stdout.sync = true
$stderr.sync = true

# Thread-safe changelog and error tracking
# Uses MonitorMixin for mutex synchronization across parallel script execution.
# All state mutations go through synchronized accessors to prevent race conditions.
require 'monitor'

class SyncState
  include MonitorMixin

  def initialize
    super()  # Initialize MonitorMixin
    @changelog = {
      events: { added: [], removed: [], updated: [] },
      groups: { added: [], removed: [], updated: [] },
      hero_images: { added: [], removed: [] },
      team: { updated: [] },
      video: { updated: nil },
      facebook_photos: { added: [], analyzed: 0, qualifying: 0 },
      reviews: { google_count: 0, updated: false }
    }
    @errors = []
    @alerts = []
    @script_results = {}
  end

  def add_error(script, message)
    synchronize do
      @errors << { script: script, message: message, time: Time.now }
      # Report to Bugsnag
      Bugsnag.notify(RuntimeError.new(message)) do |report|
        report.severity = "error"
        report.add_metadata(:sync, { script: script })
      end
    end
  end

  def add_alert(script, message)
    synchronize { @alerts << { script: script, message: message } }
  end

  def alerts
    synchronize { @alerts.dup }
  end

  def has_alerts?
    synchronize { @alerts.any? }
  end

  def set_result(script, success, duration)
    synchronize { @script_results[script] = { success: success, duration: duration } }
  end

  def errors
    synchronize { @errors.dup }
  end

  def script_results
    synchronize { @script_results.dup }
  end

  def changelog
    synchronize { @changelog }
  end

  def update_changelog(section, key, value)
    synchronize do
      if value.is_a?(Array)
        @changelog[section][key].concat(value)
      else
        @changelog[section][key] = value
      end
    end
  end

  def has_errors?
    synchronize { @errors.any? }
  end

  def has_changes?
    synchronize do
      @changelog.values.any? do |section|
        if section.is_a?(Hash)
          section.values.any? { |v| v.is_a?(Array) ? v.any? : !v.nil? }
        else
          !section.nil? && section != 0
        end
      end
    end
  end
end

$state = SyncState.new

# Store previous data for comparison
def load_previous_data(file_path)
  return nil unless File.exist?(file_path)
  JSON.parse(File.read(file_path))
rescue => e
  $state.add_error("load_data", "Failed to load #{file_path}: #{e.message}")
  nil
end

# Compare events and track changes
def track_event_changes(old_data, new_data)
  return unless old_data && new_data

  old_events = (old_data["events"] || []).map { |e| { id: e["id"], name: e["name"] } }
  new_events = (new_data["events"] || []).map { |e| { id: e["id"], name: e["name"] } }

  old_ids = old_events.map { |e| e[:id] }
  new_ids = new_events.map { |e| e[:id] }

  # Find added events
  added_ids = new_ids - old_ids
  added = added_ids.map { |id| new_events.find { |e| e[:id] == id }&.dig(:name) }.compact
  $state.update_changelog(:events, :added, added)

  # Find removed events
  removed_ids = old_ids - new_ids
  removed = removed_ids.map { |id| old_events.find { |e| e[:id] == id }&.dig(:name) }.compact
  $state.update_changelog(:events, :removed, removed)
end

# Compare groups and track changes
def track_group_changes(old_data, new_data)
  return unless old_data && new_data

  old_groups = (old_data["groups"] || []).map { |g| { id: g["id"], name: g["name"], description: g["description"] } }
  new_groups = (new_data["groups"] || []).map { |g| { id: g["id"], name: g["name"], description: g["description"] } }

  old_ids = old_groups.map { |g| g[:id] }
  new_ids = new_groups.map { |g| g[:id] }

  # Find added groups
  added_ids = new_ids - old_ids
  added = added_ids.map { |id| new_groups.find { |g| g[:id] == id }&.dig(:name) }.compact
  $state.update_changelog(:groups, :added, added)

  # Find removed groups
  removed_ids = old_ids - new_ids
  removed = removed_ids.map { |id| old_groups.find { |g| g[:id] == id }&.dig(:name) }.compact
  $state.update_changelog(:groups, :removed, removed)

  # Find updated groups (description changed)
  common_ids = old_ids & new_ids
  updated = common_ids.map do |id|
    old_group = old_groups.find { |g| g[:id] == id }
    new_group = new_groups.find { |g| g[:id] == id }
    new_group[:name] if old_group && new_group && old_group[:description] != new_group[:description]
  end.compact
  $state.update_changelog(:groups, :updated, updated)
end

# Compare hero images and track changes
def track_hero_image_changes(old_data, new_data)
  return unless old_data && new_data

  old_images = old_data["images"] || []
  new_images = new_data["images"] || []

  added = (new_images - old_images).map { |i| File.basename(i) }
  removed = (old_images - new_images).map { |i| File.basename(i) }

  $state.update_changelog(:hero_images, :added, added)
  $state.update_changelog(:hero_images, :removed, removed)
end

# Compare team data and track changes
def track_team_changes(old_data, new_data)
  return unless old_data && new_data

  old_team = old_data["team"] || []
  new_team = new_data["team"] || []

  updated = new_team.map do |new_member|
    old_member = old_team.find { |m| m["id"] == new_member["id"] }
    next unless old_member

    if old_member["bio"] != new_member["bio"] ||
       old_member["role"] != new_member["role"] ||
       old_member["hasPhoto"] != new_member["hasPhoto"]
      new_member["displayName"]
    end
  end.compact

  $state.update_changelog(:team, :updated, updated)
end

# Compare video data and track changes
def track_video_changes(old_data, new_data)
  return unless old_data && new_data

  if old_data["video_id"] != new_data["video_id"]
    $state.update_changelog(:video, :updated, new_data["title"])
  end
end

# Compare reviews data and track changes
def track_review_changes(old_data, new_data)
  return unless new_data

  old_reviews = old_data&.dig("reviews") || []
  new_reviews = new_data["reviews"] || []

  # Track if reviews were updated (different count or content)
  if old_reviews.length != new_reviews.length
    $state.update_changelog(:reviews, :updated, true)
  end

  # Track Google review count
  google_count = new_reviews.count { |r| r["source"] == "google" }
  $state.update_changelog(:reviews, :google_count, google_count)
end

# Build email body from changelog
def build_changelog_email
  lines = []
  changelog = $state.changelog
  errors = $state.errors

  if errors.any?
    lines << "⚠️  ROL.Church Daily Sync Report - ERRORS DETECTED"
  else
    lines << "ROL.Church Daily Sync Report"
  end
  lines << "=" * 50
  lines << ""
  lines << "Sync completed at: #{Time.now.strftime('%B %d, %Y at %I:%M %p %Z')}"
  lines << ""

  # Show script execution summary
  results = $state.script_results
  if results.any?
    lines << "SCRIPT EXECUTION"
    lines << "-" * 20
    results.each do |script, result|
      status = result[:success] ? "✓" : "✗"
      lines << "  #{status} #{script} (#{result[:duration].round(1)}s)"
    end
    lines << ""
  end

  # Show errors prominently at the top
  if errors.any?
    lines << "❌ ERRORS (#{errors.length})"
    lines << "-" * 20
    errors.each do |error|
      lines << "  [#{error[:script]}] #{error[:message]}"
    end
    lines << ""
  end

  # Show alerts (important notices)
  alerts = $state.alerts
  if alerts.any?
    lines << "⚠️ ALERTS"
    lines << "-" * 20
    alerts.each do |alert|
      lines << "  #{alert[:message]}"
    end
    lines << ""
  end

  has_changes = $state.has_changes?

  # Events
  if changelog[:events][:added].any? || changelog[:events][:removed].any?
    lines << "EVENTS"
    lines << "-" * 20
    changelog[:events][:added].each { |e| lines << "  + Added: #{e}" }
    changelog[:events][:removed].each { |e| lines << "  - Removed: #{e}" }
    lines << ""
  end

  # Groups
  if changelog[:groups][:added].any? || changelog[:groups][:removed].any? || changelog[:groups][:updated].any?
    lines << "GROUPS"
    lines << "-" * 20
    changelog[:groups][:added].each { |g| lines << "  + Added: #{g}" }
    changelog[:groups][:removed].each { |g| lines << "  - Removed: #{g}" }
    changelog[:groups][:updated].each { |g| lines << "  ~ Updated: #{g}" }
    lines << ""
  end

  # Hero Images
  if changelog[:hero_images][:added].any? || changelog[:hero_images][:removed].any?
    lines << "HERO IMAGES"
    lines << "-" * 20
    changelog[:hero_images][:added].each { |i| lines << "  + Added: #{i}" }
    changelog[:hero_images][:removed].each { |i| lines << "  - Removed: #{i}" }
    lines << ""
  end

  # Facebook Photos
  if changelog[:facebook_photos][:added].any?
    lines << "FACEBOOK PHOTOS"
    lines << "-" * 20
    lines << "  Analyzed: #{changelog[:facebook_photos][:analyzed]} photos"
    lines << "  Qualifying: #{changelog[:facebook_photos][:qualifying]} photos"
    changelog[:facebook_photos][:added].each { |f| lines << "  + Added: #{f}" }
    lines << ""
  end

  # Team
  if changelog[:team][:updated].any?
    lines << "TEAM"
    lines << "-" * 20
    changelog[:team][:updated].each { |t| lines << "  ~ Updated: #{t}" }
    lines << ""
  end

  # Video
  if changelog[:video][:updated]
    lines << "LATEST VIDEO"
    lines << "-" * 20
    lines << "  ~ New video: #{changelog[:video][:updated]}"
    lines << ""
  end

  if !has_changes && errors.empty?
    lines << "No changes detected in this sync."
    lines << ""
  end

  # Git diff section
  git_diff = get_git_diff
  if git_diff && !git_diff.empty?
    lines << "GIT DIFF"
    lines << "-" * 20
    lines << git_diff
    lines << ""
  end

  lines << "-" * 50
  lines << "View site: https://rol.church"
  lines << ""

  lines.join("\n")
end

# Get git diff for changed files
def get_git_diff
  # Get the project root (parent of scripts directory)
  project_root = File.expand_path("..", __dir__)

  # Get diff for tracked files that have been modified
  diff_output, status = Open3.capture2(
    "git", "-C", project_root, "diff", "--stat", "--",
    "src/data/", "public/hero/", "public/groups/", "public/team/"
  )

  return nil unless status.success? && !diff_output.strip.empty?

  # Also get a brief content diff (limited to avoid huge emails)
  content_diff, _ = Open3.capture2(
    "git", "-C", project_root, "diff", "--unified=1", "--",
    "src/data/", "public/hero/", "public/groups/", "public/team/"
  )

  # Truncate if too long (keep first 100 lines)
  diff_lines = content_diff.lines
  if diff_lines.length > 100
    content_diff = diff_lines.first(100).join + "\n... (#{diff_lines.length - 100} more lines truncated)"
  end

  "#{diff_output}\n#{content_diff}"
rescue => e
  puts "WARN: Could not get git diff: #{e.message}"
  nil
end

# Send changelog email via AWS SES
def send_changelog_email
  email_body = build_changelog_email
  has_errors = $state.has_errors?
  has_changes = $state.has_changes?

  puts "\n" + "=" * 50
  puts "CHANGELOG SUMMARY"
  puts "=" * 50
  puts email_body

  has_alerts = $state.has_alerts?

  # Always send email if there are errors or alerts, otherwise only if there are changes
  unless has_errors || has_alerts || has_changes
    puts "INFO: No changes, errors, or alerts to report, skipping email"
    return
  end

  # Check for AWS SES configuration
  from_email = ENV["SES_FROM_EMAIL"]
  recipient = ENV["CHANGELOG_EMAIL"] || "david.plappert@rol.church"
  aws_region = ENV["AWS_REGION"] || "us-east-1"

  unless from_email
    puts "INFO: SES_FROM_EMAIL not configured, email not sent"
    puts "INFO: Set SES_FROM_EMAIL to a verified sender in AWS SES"
    return
  end

  unless ENV["AWS_ACCESS_KEY_ID"] && ENV["AWS_SECRET_ACCESS_KEY"]
    puts "INFO: AWS credentials not configured, email not sent"
    return
  end

  # Build subject line based on status
  date_str = Time.now.strftime('%m/%d/%Y')
  subject = if has_errors
    "⚠️ ROL.Church Sync FAILED - #{date_str}"
  elsif has_alerts
    "⚠️ ROL.Church Sync Report - #{date_str} (Action Needed)"
  elsif has_changes
    "ROL.Church Sync Report - #{date_str}"
  else
    "ROL.Church Sync Report - #{date_str} (No Changes)"
  end

  begin
    require "aws-sdk-ses"

    ses = Aws::SES::Client.new(
      region: aws_region,
      ssl_verify_peer: false  # Workaround for CRL issues
    )

    ses.send_email({
      source: from_email,
      destination: {
        to_addresses: [recipient]
      },
      message: {
        subject: {
          data: subject,
          charset: "UTF-8"
        },
        body: {
          text: {
            data: email_body,
            charset: "UTF-8"
          }
        }
      }
    })

    puts "INFO: Changelog email sent to #{recipient} via AWS SES"
  rescue Aws::SES::Errors::ServiceError => e
    puts "ERROR: AWS SES error: #{e.message}"
  rescue LoadError
    puts "ERROR: aws-sdk-ses gem not installed"
    puts "Run: bundle add aws-sdk-ses"
  rescue => e
    puts "ERROR: Failed to send email: #{e.message}"
  end
end

# Run a single sync script with error handling
# Uses subprocess execution (Open3.capture2e) for several important reasons:
#   1. Isolates script failures - one script crash doesn't kill the orchestrator
#   2. Captures stdout/stderr cleanly without thread interleaving issues
#   3. Allows proper environment variable passing to each subprocess
#   4. Exit codes are properly captured for success/failure detection
#
# Output handling:
#   - Shows first 3 and last 5 lines for long output
#   - Always shows DEBUG, ERROR, WARNING, ALERT lines
#   - Prefixes all output with [script_name] for clarity
def run_script(script)
  script_name = File.basename(script, '.rb')
  start_time = Time.now
  success = false

  puts "[#{script_name}] Starting..."

  begin
    # Run script as subprocess to capture output cleanly
    script_path = File.join(__dir__, script)
    output, status = Open3.capture2e(
      {
        'ROL_PLANNING_CENTER_CLIENT_ID' => ENV['ROL_PLANNING_CENTER_CLIENT_ID'],
        'ROL_PLANNING_CENTER_SECRET' => ENV['ROL_PLANNING_CENTER_SECRET'],
        'PCO_WEBSITE_HERO_MEDIA_ID' => ENV['PCO_WEBSITE_HERO_MEDIA_ID'],
        'CLOUDFLARE_API_TOKEN' => ENV['CLOUDFLARE_API_TOKEN'],
        'CLOUDFLARE_ACCOUNT_ID' => ENV['CLOUDFLARE_ACCOUNT_ID'],
        'FB_PAGE_ID' => ENV['FB_PAGE_ID'],
        'FB_PAGE_ACCESS_TOKEN' => ENV['FB_PAGE_ACCESS_TOKEN'],
        'AWS_ACCESS_KEY_ID' => ENV['AWS_ACCESS_KEY_ID'],
        'AWS_SECRET_ACCESS_KEY' => ENV['AWS_SECRET_ACCESS_KEY'],
        'AWS_REGION' => ENV['AWS_REGION'] || 'us-east-1',
        'GOOGLE_PLACES_API_KEY' => ENV['GOOGLE_PLACES_API_KEY'],
        'GOOGLE_PLACE_ID' => ENV['GOOGLE_PLACE_ID'],
        'TZ' => 'America/Chicago',
        'BUNDLE_GEMFILE' => File.join(__dir__, 'Gemfile')
      },
      'bundle', 'exec', 'ruby', script_path
    )

    duration = Time.now - start_time
    success = status.success?

    # Check for ERROR in output even if exit code was 0
    if output =~ /^ERROR[:\s]/im
      error_lines = output.lines.select { |l| l =~ /^ERROR[:\s]/i }.map(&:strip).first(3)
      error_lines.each { |err| $state.add_error(script_name, err) }
      success = false
    end

    # Check for ALERT lines (important notices for email)
    if output =~ /^ALERT[:\s]/im
      alert_lines = output.lines.select { |l| l =~ /^ALERT[:\s]/i }.map(&:strip)
      alert_lines.each { |alert| $state.add_alert(script_name, alert.sub(/^ALERT:\s*/i, '')) }
    end

    # Print output with prefix (summarized for parallel readability)
    output_lines = output.lines

    # Always show DEBUG, ERROR, WARNING, and ALERT lines
    important_lines = output_lines.select { |l| l =~ /(DEBUG|ERROR|WARNING|WARN|ALERT)/i }

    if output_lines.length > 10
      # Show first 3 and last 5 lines for long output
      output_lines.first(3).each { |line| puts "[#{script_name}] #{line.chomp}" }
      puts "[#{script_name}] ... (#{output_lines.length - 8} lines omitted)"
      # Show important lines that weren't in first 3 or last 5
      first_last_lines = output_lines.first(3) + output_lines.last(5)
      important_lines.each do |line|
        unless first_last_lines.include?(line)
          puts "[#{script_name}] #{line.chomp}"
        end
      end
      output_lines.last(5).each { |line| puts "[#{script_name}] #{line.chomp}" }
    else
      output_lines.each { |line| puts "[#{script_name}] #{line.chomp}" }
    end

    unless success
      $state.add_error(script_name, "Exit code: #{status.exitstatus}") unless $state.errors.any? { |e| e[:script] == script_name }
    end

    puts "[#{script_name}] #{success ? 'Completed' : 'FAILED'} in #{duration.round(1)}s"
    $state.set_result(script_name, success, duration)

  rescue => e
    duration = Time.now - start_time
    error_msg = "#{e.class}: #{e.message}"
    puts "[#{script_name}] FAILED: #{error_msg}"
    $state.add_error(script_name, error_msg)
    $state.set_result(script_name, false, duration)
  end

  success
end

puts "=" * 50
puts "Daily Website Sync"
puts "=" * 50
puts

# Check for required environment variables
unless ENV["ROL_PLANNING_CENTER_CLIENT_ID"] && ENV["ROL_PLANNING_CENTER_SECRET"]
  puts "ERROR: Missing ROL_PLANNING_CENTER_CLIENT_ID or ROL_PLANNING_CENTER_SECRET environment variables"
  puts "Set these in GitHub Actions secrets or in scripts/.env for local development"
  exit 1
end

# Data file paths
DATA_DIR = File.join(__dir__, "..", "src", "data")
EVENTS_FILE = File.join(DATA_DIR, "events.json")
GROUPS_FILE = File.join(DATA_DIR, "groups.json")
HERO_IMAGES_FILE = File.join(DATA_DIR, "hero_images.json")
TEAM_FILE = File.join(DATA_DIR, "team.json")
VIDEO_FILE = File.join(DATA_DIR, "cloudflare_video.json")
REVIEWS_FILE = File.join(DATA_DIR, "reviews.json")

# Load previous data for comparison (in parallel)
puts "Loading previous data..."
prev_data = {}
Parallel.each(
  [
    [:events, EVENTS_FILE],
    [:groups, GROUPS_FILE],
    [:hero_images, HERO_IMAGES_FILE],
    [:team, TEAM_FILE],
    [:video, VIDEO_FILE],
    [:reviews, REVIEWS_FILE]
  ],
  in_threads: 6
) do |key, file|
  prev_data[key] = load_previous_data(file)
end

# Parse command line arguments
skip_cloudflare = ARGV.include?('--skip-cloudflare')

if skip_cloudflare
  puts "INFO: Skipping Cloudflare sync (--skip-cloudflare flag set)"
end

# Scripts organized by dependency groups
# Group 1: Independent scripts that can run in parallel
# Group 2: Scripts that depend on Group 1 (hero_images depends on facebook_photos)
# Group 3: Scripts that can run after Group 1

group1_scripts = %w[
  sync_events.rb
  sync_groups.rb
  sync_facebook_photos.rb
  sync_team.rb
  sync_reviews.rb
]

# Only include Cloudflare sync if not skipped
unless skip_cloudflare
  group1_scripts << 'sync_cloudflare_video.rb'
end

group2_scripts = %w[
  sync_hero_images.rb
]

total_start = Time.now

# Run Group 1 in parallel
puts "\n" + "-" * 50
puts "Running parallel sync scripts..."
puts "-" * 50

Parallel.each(group1_scripts, in_threads: group1_scripts.length) do |script|
  run_script(script)
end

# Run Group 2 (depends on facebook_photos completing)
puts "\n" + "-" * 50
puts "Running dependent sync scripts..."
puts "-" * 50

group2_scripts.each do |script|
  run_script(script)
end

total_duration = Time.now - total_start
puts "\n" + "-" * 50
puts "All scripts completed in #{total_duration.round(1)}s"
puts "-" * 50

# Load new data and track changes (in parallel)
puts "\nLoading new data and tracking changes..."
new_data = {}
Parallel.each(
  [
    [:events, EVENTS_FILE],
    [:groups, GROUPS_FILE],
    [:hero_images, HERO_IMAGES_FILE],
    [:team, TEAM_FILE],
    [:video, VIDEO_FILE],
    [:reviews, REVIEWS_FILE]
  ],
  in_threads: 6
) do |key, file|
  new_data[key] = load_previous_data(file)
end

# Track all changes
track_event_changes(prev_data[:events], new_data[:events])
track_group_changes(prev_data[:groups], new_data[:groups])
track_hero_image_changes(prev_data[:hero_images], new_data[:hero_images])
track_team_changes(prev_data[:team], new_data[:team])
track_video_changes(prev_data[:video], new_data[:video])
track_review_changes(prev_data[:reviews], new_data[:reviews])

puts
puts "=" * 50
puts "Sync complete!"
if $state.has_errors?
  puts "⚠️  COMPLETED WITH ERRORS"
end
puts "=" * 50

# Send changelog email
send_changelog_email

# Exit with error code if any scripts failed
exit($state.has_errors? ? 1 : 0)
