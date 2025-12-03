#!/usr/bin/env ruby
# frozen_string_literal: true

# Run all sync scripts and send a changelog email via AWS SES
# Usage: ruby sync_all.rb
#
# Environment variables for email (uses existing AWS credentials from Rekognition):
#   AWS_ACCESS_KEY_ID - AWS access key (already set for Rekognition)
#   AWS_SECRET_ACCESS_KEY - AWS secret key (already set for Rekognition)
#   AWS_REGION - AWS region (default: us-east-1)
#   SES_FROM_EMAIL - Sender email (must be verified in SES)
#   CHANGELOG_EMAIL - Recipient email (default: david.plappert@rol.church)

require "bundler/setup"
require "dotenv"
require "json"
require "time"

# Load environment variables from .env file (for local development)
Dotenv.load(File.join(__dir__, ".env")) if File.exist?(File.join(__dir__, ".env"))

# Set timezone to Central Time
ENV['TZ'] = 'America/Chicago'

# Force immediate output
$stdout.sync = true
$stderr.sync = true

# Changelog tracking
$changelog = {
  events: { added: [], removed: [], updated: [] },
  groups: { added: [], removed: [], updated: [] },
  hero_images: { added: [], removed: [] },
  team: { updated: [] },
  video: { updated: nil },
  facebook_photos: { added: [], analyzed: 0, qualifying: 0 }
}

# Store previous data for comparison
def load_previous_data(file_path)
  return nil unless File.exist?(file_path)
  JSON.parse(File.read(file_path))
rescue
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
  added_ids.each do |id|
    event = new_events.find { |e| e[:id] == id }
    $changelog[:events][:added] << event[:name] if event
  end

  # Find removed events
  removed_ids = old_ids - new_ids
  removed_ids.each do |id|
    event = old_events.find { |e| e[:id] == id }
    $changelog[:events][:removed] << event[:name] if event
  end
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
  added_ids.each do |id|
    group = new_groups.find { |g| g[:id] == id }
    $changelog[:groups][:added] << group[:name] if group
  end

  # Find removed groups
  removed_ids = old_ids - new_ids
  removed_ids.each do |id|
    group = old_groups.find { |g| g[:id] == id }
    $changelog[:groups][:removed] << group[:name] if group
  end

  # Find updated groups (description changed)
  common_ids = old_ids & new_ids
  common_ids.each do |id|
    old_group = old_groups.find { |g| g[:id] == id }
    new_group = new_groups.find { |g| g[:id] == id }
    if old_group && new_group && old_group[:description] != new_group[:description]
      $changelog[:groups][:updated] << new_group[:name]
    end
  end
end

# Compare hero images and track changes
def track_hero_image_changes(old_data, new_data)
  return unless old_data && new_data

  old_images = old_data["images"] || []
  new_images = new_data["images"] || []

  added = new_images - old_images
  removed = old_images - new_images

  $changelog[:hero_images][:added] = added.map { |i| File.basename(i) }
  $changelog[:hero_images][:removed] = removed.map { |i| File.basename(i) }
end

# Compare team data and track changes
def track_team_changes(old_data, new_data)
  return unless old_data && new_data

  old_team = old_data["team"] || []
  new_team = new_data["team"] || []

  new_team.each do |new_member|
    old_member = old_team.find { |m| m["id"] == new_member["id"] }
    next unless old_member

    # Check for meaningful changes
    if old_member["bio"] != new_member["bio"] ||
       old_member["role"] != new_member["role"] ||
       old_member["hasPhoto"] != new_member["hasPhoto"]
      $changelog[:team][:updated] << new_member["displayName"]
    end
  end
end

# Compare video data and track changes
def track_video_changes(old_data, new_data)
  return unless old_data && new_data

  if old_data["video_id"] != new_data["video_id"]
    $changelog[:video][:updated] = new_data["title"]
  end
end

# Build email body from changelog
def build_changelog_email
  lines = []
  lines << "ROL.Church Daily Sync Report"
  lines << "=" * 40
  lines << ""
  lines << "Sync completed at: #{Time.now.strftime('%B %d, %Y at %I:%M %p %Z')}"
  lines << ""

  has_changes = false

  # Events
  if $changelog[:events][:added].any? || $changelog[:events][:removed].any?
    has_changes = true
    lines << "EVENTS"
    lines << "-" * 20
    $changelog[:events][:added].each { |e| lines << "  + Added: #{e}" }
    $changelog[:events][:removed].each { |e| lines << "  - Removed: #{e}" }
    lines << ""
  end

  # Groups
  if $changelog[:groups][:added].any? || $changelog[:groups][:removed].any? || $changelog[:groups][:updated].any?
    has_changes = true
    lines << "GROUPS"
    lines << "-" * 20
    $changelog[:groups][:added].each { |g| lines << "  + Added: #{g}" }
    $changelog[:groups][:removed].each { |g| lines << "  - Removed: #{g}" }
    $changelog[:groups][:updated].each { |g| lines << "  ~ Updated: #{g}" }
    lines << ""
  end

  # Hero Images
  if $changelog[:hero_images][:added].any? || $changelog[:hero_images][:removed].any?
    has_changes = true
    lines << "HERO IMAGES"
    lines << "-" * 20
    $changelog[:hero_images][:added].each { |i| lines << "  + Added: #{i}" }
    $changelog[:hero_images][:removed].each { |i| lines << "  - Removed: #{i}" }
    lines << ""
  end

  # Facebook Photos
  if $changelog[:facebook_photos][:added].any?
    has_changes = true
    lines << "FACEBOOK PHOTOS"
    lines << "-" * 20
    lines << "  Analyzed: #{$changelog[:facebook_photos][:analyzed]} photos"
    lines << "  Qualifying: #{$changelog[:facebook_photos][:qualifying]} photos"
    $changelog[:facebook_photos][:added].each { |f| lines << "  + Added: #{f}" }
    lines << ""
  end

  # Team
  if $changelog[:team][:updated].any?
    has_changes = true
    lines << "TEAM"
    lines << "-" * 20
    $changelog[:team][:updated].each { |t| lines << "  ~ Updated: #{t}" }
    lines << ""
  end

  # Video
  if $changelog[:video][:updated]
    has_changes = true
    lines << "LATEST VIDEO"
    lines << "-" * 20
    lines << "  ~ New video: #{$changelog[:video][:updated]}"
    lines << ""
  end

  unless has_changes
    lines << "No changes detected in this sync."
    lines << ""
  end

  lines << "-" * 40
  lines << "View site: https://rol.church"
  lines << ""

  lines.join("\n")
end

# Send changelog email via AWS SES
def send_changelog_email
  email_body = build_changelog_email

  # Check if there are any changes worth reporting
  has_changes = $changelog.values.any? do |section|
    if section.is_a?(Hash)
      section.values.any? { |v| v.is_a?(Array) ? v.any? : !v.nil? }
    else
      !section.nil? && section != 0
    end
  end

  puts "\n" + "=" * 50
  puts "CHANGELOG SUMMARY"
  puts "=" * 50
  puts email_body

  # Only send email if there are changes
  unless has_changes
    puts "INFO: No changes to report, skipping email"
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
          data: "ROL.Church Sync Report - #{Time.now.strftime('%m/%d/%Y')}",
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

puts "=" * 50
puts "Planning Center Sync"
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

# Load previous data for comparison
prev_events = load_previous_data(EVENTS_FILE)
prev_groups = load_previous_data(GROUPS_FILE)
prev_hero_images = load_previous_data(HERO_IMAGES_FILE)
prev_team = load_previous_data(TEAM_FILE)
prev_video = load_previous_data(VIDEO_FILE)

# Run each sync script
# Note: sync_facebook_photos.rb runs BEFORE sync_hero_images.rb so that
# Facebook photos are downloaded and optimized before hero_images.json is generated
scripts = %w[
  sync_events.rb
  sync_groups.rb
  sync_facebook_photos.rb
  sync_hero_images.rb
  sync_team.rb
  sync_cloudflare_video.rb
]

scripts.each do |script|
  puts "\nRunning #{script}..."
  puts "-" * 30
  load File.join(__dir__, script)
end

# Load new data and track changes
new_events = load_previous_data(EVENTS_FILE)
new_groups = load_previous_data(GROUPS_FILE)
new_hero_images = load_previous_data(HERO_IMAGES_FILE)
new_team = load_previous_data(TEAM_FILE)
new_video = load_previous_data(VIDEO_FILE)

# Track all changes
track_event_changes(prev_events, new_events)
track_group_changes(prev_groups, new_groups)
track_hero_image_changes(prev_hero_images, new_hero_images)
track_team_changes(prev_team, new_team)
track_video_changes(prev_video, new_video)

puts
puts "=" * 50
puts "Sync complete!"
puts "=" * 50

# Send changelog email
send_changelog_email
