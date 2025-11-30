#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync latest Sunday service video ID from Cloudflare Stream
# Usage: ruby sync_cloudflare_video.rb
#
# This script fetches recordings from the Cloudflare Stream Live Input
# and finds the most recent SUNDAY service recording to display on the
# Watch Live page when not streaming live.
#
# Environment variables required:
#   CLOUDFLARE_ACCOUNT_ID - Cloudflare account ID
#   CLOUDFLARE_API_TOKEN - Cloudflare API token with Stream read access
#
# The script updates src/pages/live.astro with the latest video ID.

require "bundler/setup"
require "net/http"
require "json"
require "time"

# Set timezone to Central Time
ENV["TZ"] = "America/Chicago"

# Configuration
CLOUDFLARE_ACCOUNT_ID = ENV["CLOUDFLARE_ACCOUNT_ID"] || "cc666c3ac6a916af4fd2d8de07a1b985"
CLOUDFLARE_API_TOKEN = ENV["CLOUDFLARE_API_TOKEN"]
LIVE_INPUT_ID = "7b2cc63f97205c30dfa1b6c1ed7c8a93"
LIVE_ASTRO_PATH = File.expand_path("../src/pages/live.astro", __dir__)

def fetch_recordings
  uri = URI("https://api.cloudflare.com/client/v4/accounts/#{CLOUDFLARE_ACCOUNT_ID}/stream/live_inputs/#{LIVE_INPUT_ID}/videos")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{CLOUDFLARE_API_TOKEN}"
  request["Content-Type"] = "application/json"

  response = http.request(request)

  if response.code != "200"
    puts "ERROR: Failed to fetch recordings from Cloudflare"
    puts "Response: #{response.body}"
    exit 1
  end

  data = JSON.parse(response.body)

  unless data["success"]
    puts "ERROR: Cloudflare API returned error"
    puts "Errors: #{data['errors']}"
    exit 1
  end

  data["result"] || []
end

def find_latest_sunday_recording(recordings)
  # Filter to only "ready" recordings
  ready_recordings = recordings.select { |r| r["status"]&.dig("state") == "ready" }

  if ready_recordings.empty?
    puts "No ready recordings found"
    return nil
  end

  # Parse dates and find Sunday recordings
  # Cloudflare recordings have "created" timestamp
  sunday_recordings = ready_recordings.select do |recording|
    created_at = Time.parse(recording["created"])
    # Sunday is day 0 in Ruby's wday
    # Service is 10am-12:30pm, so check if created on Sunday during/after service
    created_at.wday == 0 && created_at.hour >= 10
  end

  if sunday_recordings.empty?
    puts "No Sunday recordings found, using most recent recording"
    # Fall back to most recent recording if no Sunday recordings
    return ready_recordings.max_by { |r| Time.parse(r["created"]) }
  end

  # Return the most recent Sunday recording
  sunday_recordings.max_by { |r| Time.parse(r["created"]) }
end

def update_live_astro(video_id)
  unless File.exist?(LIVE_ASTRO_PATH)
    puts "ERROR: #{LIVE_ASTRO_PATH} not found"
    exit 1
  end

  content = File.read(LIVE_ASTRO_PATH)

  # Update the video ID in the frontmatter
  updated_content = content.gsub(
    /const CLOUDFLARE_LATEST_VIDEO_ID = '[a-f0-9]+';/,
    "const CLOUDFLARE_LATEST_VIDEO_ID = '#{video_id}';"
  )

  # Also update in the script section
  updated_content = updated_content.gsub(
    /const CLOUDFLARE_LATEST_VIDEO_ID = '[a-f0-9]+';/,
    "const CLOUDFLARE_LATEST_VIDEO_ID = '#{video_id}';"
  )

  if content == updated_content
    puts "Video ID unchanged (#{video_id})"
    return false
  end

  File.write(LIVE_ASTRO_PATH, updated_content)
  puts "Updated video ID to: #{video_id}"
  true
end

def main
  puts "Syncing Cloudflare Stream video ID..."
  puts "-" * 40

  unless CLOUDFLARE_API_TOKEN
    puts "ERROR: CLOUDFLARE_API_TOKEN environment variable not set"
    puts "Set this in GitHub Actions secrets or in scripts/.env for local development"
    exit 1
  end

  # Fetch all recordings from the live input
  puts "Fetching recordings from Cloudflare Stream..."
  recordings = fetch_recordings
  puts "Found #{recordings.length} total recordings"

  # Find the latest Sunday recording
  latest = find_latest_sunday_recording(recordings)

  if latest.nil?
    puts "No suitable recording found"
    exit 0
  end

  video_id = latest["uid"]
  created_at = Time.parse(latest["created"])
  duration = latest["duration"] || 0
  duration_str = "#{(duration / 60).to_i}m #{(duration % 60).to_i}s"

  puts "Latest Sunday recording:"
  puts "  Video ID: #{video_id}"
  puts "  Created: #{created_at.strftime('%A, %B %d, %Y at %I:%M %p %Z')}"
  puts "  Duration: #{duration_str}"

  # Update the live.astro file
  updated = update_live_astro(video_id)

  if updated
    puts "\nSuccessfully updated live.astro with new video ID"
  else
    puts "\nNo changes needed"
  end
end

main
