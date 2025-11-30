#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync latest Sunday service video ID from Cloudflare Stream
# Usage: ruby sync_cloudflare_video.rb
#
# This script fetches recordings from the Cloudflare Stream Live Input
# and finds the most recent SUNDAY service recording to display on the
# Watch Live page when not streaming live.
#
# It also syncs video metadata (title, name, etc.) from Planning Center
# service plans to Cloudflare Stream videos.
#
# Environment variables required:
#   CLOUDFLARE_ACCOUNT_ID - Cloudflare account ID
#   CLOUDFLARE_API_TOKEN - Cloudflare API token with Stream read/write access
#   ROL_PLANNING_CENTER_CLIENT_ID - Planning Center API client ID
#   ROL_PLANNING_CENTER_SECRET - Planning Center API secret
#
# The script updates src/pages/live.astro with the latest video ID.

require "bundler/setup"
require "net/http"
require "json"
require "time"
require "openssl"
require_relative "pco_client"

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
  http.verify_mode = OpenSSL::SSL::VERIFY_PEER

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

def fetch_video_details(video_id)
  uri = URI("https://api.cloudflare.com/client/v4/accounts/#{CLOUDFLARE_ACCOUNT_ID}/stream/#{video_id}")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_PEER

  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{CLOUDFLARE_API_TOKEN}"
  request["Content-Type"] = "application/json"

  response = http.request(request)

  if response.code != "200"
    puts "  ERROR: Failed to fetch video details for #{video_id}"
    return nil
  end

  data = JSON.parse(response.body)
  data["result"]
end

def fetch_service_plans(start_date, end_date)
  # Fetch plans from Planning Center Services
  pco = PCO::Client.api

  plans = []

  begin
    # Get all service types
    service_types = pco.services.v2.service_types.get
    puts "  Found #{service_types['data'].length} service types"

    service_types["data"].each do |service_type|
      service_type_id = service_type["id"]
      service_type_name = service_type["attributes"]["name"]

      # Fetch plans for this service type - use no_dates filter to get all, then filter by date
      # The API doesn't support date range filtering well, so get recent plans
      type_plans = pco.services.v2.service_types[service_type_id].plans.get(
        per_page: 100,
        order: "-sort_date"
      )

      puts "  #{service_type_name}: #{type_plans['data'].length} plans"

      type_plans["data"].each do |plan|
        plan_date_str = plan["attributes"]["dates"]
        sort_date = plan["attributes"]["sort_date"]

        next unless sort_date

        plan_date = Date.parse(sort_date)

        # Only include plans within the date range
        if plan_date >= start_date && plan_date <= end_date
          plans << {
            id: plan["id"],
            title: plan["attributes"]["title"],
            series_title: plan["attributes"]["series_title"],
            dates: plan_date_str,
            date: plan_date,
            service_type_id: service_type_id,
            service_type_name: service_type_name
          }
          puts "    + #{plan_date}: #{plan['attributes']['title']}"
        end
      end
    end
  rescue => e
    puts "  ERROR fetching plans: #{e.message}"
    puts e.backtrace.first(5).join("\n")
  end

  plans
end

def update_cloudflare_video(video_id, metadata)
  uri = URI("https://api.cloudflare.com/client/v4/accounts/#{CLOUDFLARE_ACCOUNT_ID}/stream/#{video_id}")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_PEER

  request = Net::HTTP::Post.new(uri)
  request["Authorization"] = "Bearer #{CLOUDFLARE_API_TOKEN}"
  request["Content-Type"] = "application/json"

  # Build update payload
  payload = {
    meta: {
      name: metadata[:video_name]
    },
    creator: metadata[:creator],
    allowedOrigins: metadata[:allowed_origins],
    publicDetails: {
      title: metadata[:title],
      logo: metadata[:logo],
      share_link: metadata[:share_link],
      channel_link: metadata[:channel_link]
    }
  }

  request.body = payload.to_json
  response = http.request(request)

  if response.code != "200"
    puts "  ERROR: Failed to update video #{video_id}"
    puts "  Response: #{response.body}"
    return false
  end

  data = JSON.parse(response.body)
  data["success"]
end

def sync_video_metadata(recordings)
  puts "\n" + "=" * 40
  puts "Syncing video metadata from Planning Center..."
  puts "=" * 40

  # Find videos that need metadata update (no public details title)
  videos_to_update = recordings.select do |recording|
    recording["status"]&.dig("state") == "ready" &&
      (recording.dig("publicDetails", "title").nil? || recording.dig("publicDetails", "title").to_s.empty?)
  end

  if videos_to_update.empty?
    puts "No videos need metadata updates"
    return
  end

  puts "Found #{videos_to_update.length} videos needing metadata updates"

  # Get date range for Planning Center query (oldest to newest video)
  # Use Chicago time for the video dates since services are scheduled in Chicago time
  video_dates = videos_to_update.map do |v|
    # Parse the UTC time and it will be converted to Chicago time due to ENV['TZ']
    Time.parse(v["created"]).to_date
  end
  start_date = video_dates.min - 7 # Week before earliest video
  end_date = video_dates.max + 1   # Day after latest video

  puts "Fetching Planning Center plans from #{start_date} to #{end_date}..."
  plans = fetch_service_plans(start_date, end_date)
  puts "Found #{plans.length} service plans"

  # Match videos to plans based on date
  videos_to_update.each do |video|
    video_id = video["uid"]
    # Parse UTC time and convert to local (Chicago) time for proper date matching
    video_created_utc = Time.parse(video["created"])
    video_created = video_created_utc.getlocal
    video_date = video_created.to_date

    puts "\nProcessing video: #{video_id}"
    puts "  Created: #{video_created_utc.strftime('%Y-%m-%d %H:%M UTC')} (#{video_created.strftime('%Y-%m-%d %H:%M %Z')})"

    # Find matching plan (same date)
    matching_plan = plans.find { |p| p[:date] == video_date }

    unless matching_plan
      puts "  No matching Planning Center plan found for #{video_date}"
      next
    end

    puts "  Matched to plan: #{matching_plan[:title]} (#{matching_plan[:service_type_name]})"

    # Skip if plan title is empty
    if matching_plan[:title].nil? || matching_plan[:title].strip.empty?
      puts "  Skipping - plan has no title"
      next
    end

    # Build the video title: MM/DD: Plan Title - Service Type Name
    # Use the plan date for the title prefix
    date_prefix = matching_plan[:date].strftime("%-m/%-d")
    video_title = "#{date_prefix}: #{matching_plan[:title]} - #{matching_plan[:service_type_name]}"

    metadata = {
      video_name: video_title,
      creator: "River of Life",
      allowed_origins: ["dev.rol.church", "rol.church"],
      title: video_title,
      logo: "https://rol.church/favicon.png",
      share_link: "https://rol.church/live?share=1",
      channel_link: "https://rol.church/live?channel=1"
    }

    puts "  Setting title: #{video_title}"

    if update_cloudflare_video(video_id, metadata)
      puts "  ✓ Updated successfully"
    else
      puts "  ✗ Update failed"
    end
  end
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

  # Sync video metadata from Planning Center
  sync_video_metadata(recordings)

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
