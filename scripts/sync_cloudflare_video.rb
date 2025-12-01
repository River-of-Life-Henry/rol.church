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
require "fileutils"
require_relative "pco_client"

# Set timezone to Central Time
ENV["TZ"] = "America/Chicago"

# Configuration
CLOUDFLARE_ACCOUNT_ID = ENV["CLOUDFLARE_ACCOUNT_ID"] || "cc666c3ac6a916af4fd2d8de07a1b985"
CLOUDFLARE_API_TOKEN = ENV["CLOUDFLARE_API_TOKEN"]
LIVE_INPUT_ID = "7b2cc63f97205c30dfa1b6c1ed7c8a93"
LIVE_ASTRO_PATH = File.expand_path("../src/pages/live.astro", __dir__)
VIDEO_DATA_PATH = File.expand_path("../src/data/cloudflare_video.json", __dir__)

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
  series_cache = {} # Cache series artwork by ID

  begin
    # Get all service types
    service_types = pco.services.v2.service_types.get
    puts "  Found #{service_types['data'].length} service types"

    service_types["data"].each do |service_type|
      service_type_id = service_type["id"]
      service_type_name = service_type["attributes"]["name"]

      # Fetch plans for this service type with series included
      type_plans = pco.services.v2.service_types[service_type_id].plans.get(
        per_page: 100,
        order: "-sort_date",
        include: "series"
      )

      # Build series cache from included data
      type_plans["included"]&.each do |item|
        next unless item["type"] == "Series"
        series_id = item["id"]
        series_cache[series_id] ||= {
          title: item["attributes"]["title"],
          artwork_url: item["attributes"]["artwork_for_plan"] || item["attributes"]["artwork_original"]
        }
      end

      puts "  #{service_type_name}: #{type_plans['data'].length} plans"

      type_plans["data"].each do |plan|
        plan_date_str = plan["attributes"]["dates"]
        sort_date = plan["attributes"]["sort_date"]

        next unless sort_date

        plan_date = Date.parse(sort_date)

        # Only include plans within the date range
        if plan_date >= start_date && plan_date <= end_date
          series_id = plan.dig("relationships", "series", "data", "id")
          series_info = series_id ? series_cache[series_id] : nil

          plans << {
            id: plan["id"],
            title: plan["attributes"]["title"],
            series_title: plan["attributes"]["series_title"],
            series_artwork_url: series_info&.dig(:artwork_url),
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

def build_expected_title(plan)
  date_prefix = plan[:date].strftime("%-m/%-d/%Y")
  plan_title = plan[:title]&.strip

  if plan_title.nil? || plan_title.empty?
    # No plan title, just use date and service type
    "#{date_prefix}: #{plan[:service_type_name]}"
  else
    # Full format: MM/DD/YYYY: Plan Title - Service Type Name
    "#{date_prefix}: #{plan_title} - #{plan[:service_type_name]}"
  end
end

def sync_video_metadata(recordings)
  puts "\n" + "=" * 40
  puts "Syncing video metadata from Planning Center..."
  puts "=" * 40

  # Only process ready recordings
  ready_recordings = recordings.select do |recording|
    recording["status"]&.dig("state") == "ready"
  end

  if ready_recordings.empty?
    puts "No ready recordings found"
    return {}
  end

  puts "Found #{ready_recordings.length} ready recordings"

  # Get date range for Planning Center query
  video_dates = ready_recordings.map do |v|
    Time.parse(v["created"]).getlocal.to_date
  end
  start_date = video_dates.min - 7
  end_date = video_dates.max + 1

  puts "Fetching Planning Center plans from #{start_date} to #{end_date}..."
  plans = fetch_service_plans(start_date, end_date)
  puts "Found #{plans.length} service plans"

  # Track video-to-plan matches for returning
  video_plan_matches = {}

  # Check each video to see if it needs updating
  ready_recordings.each do |video|
    video_id = video["uid"]
    video_created_utc = Time.parse(video["created"])
    video_created = video_created_utc.getlocal
    video_date = video_created.to_date
    current_title = video.dig("publicDetails", "title")

    # Find matching plan (same date)
    matching_plan = plans.find { |p| p[:date] == video_date }

    unless matching_plan
      # No matching plan - skip silently unless there's no title at all
      if current_title.nil? || current_title.to_s.empty?
        puts "\nProcessing video: #{video_id}"
        puts "  Created: #{video_created_utc.strftime('%Y-%m-%d %H:%M UTC')} (#{video_created.strftime('%Y-%m-%d %H:%M %Z')})"
        puts "  No matching Planning Center plan found for #{video_date}"
      end
      next
    end

    # Store the match for later use
    video_plan_matches[video_id] = matching_plan

    # Build the expected title
    expected_title = build_expected_title(matching_plan)

    # Skip if title already matches
    if current_title == expected_title
      next
    end

    puts "\nProcessing video: #{video_id}"
    puts "  Created: #{video_created_utc.strftime('%Y-%m-%d %H:%M UTC')} (#{video_created.strftime('%Y-%m-%d %H:%M %Z')})"
    puts "  Matched to plan: #{matching_plan[:title] || '(no title)'} (#{matching_plan[:service_type_name]})"
    puts "  Current title: #{current_title || '(none)'}"
    puts "  Expected title: #{expected_title}"

    metadata = {
      video_name: expected_title,
      creator: "River of Life",
      allowed_origins: ["dev.rol.church", "rol.church"],
      title: expected_title,
      logo: "https://rol.church/favicon.png",
      share_link: "https://rol.church/live?share=1",
      channel_link: "https://rol.church/live?channel=1"
    }

    if update_cloudflare_video(video_id, metadata)
      puts "  ✓ Updated successfully"
    else
      puts "  ✗ Update failed"
    end
  end

  video_plan_matches
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

def save_video_data(video_id, video, matching_plan)
  video_data = {
    video_id: video_id,
    title: matching_plan ? build_expected_title(matching_plan) : video.dig("publicDetails", "title"),
    created: video["created"],
    duration: video["duration"],
    thumbnail: video["thumbnail"],
    poster_url: matching_plan&.dig(:series_artwork_url),
    series_title: matching_plan&.dig(:series_title),
    plan_title: matching_plan&.dig(:title),
    service_type: matching_plan&.dig(:service_type_name),
    updated_at: Time.now.utc.iso8601
  }

  # Ensure the data directory exists
  FileUtils.mkdir_p(File.dirname(VIDEO_DATA_PATH))

  # Read existing data if it exists
  existing_data = if File.exist?(VIDEO_DATA_PATH)
    JSON.parse(File.read(VIDEO_DATA_PATH))
  else
    {}
  end

  # Check if data has changed
  if existing_data["video_id"] == video_data[:video_id] &&
     existing_data["poster_url"] == video_data[:poster_url] &&
     existing_data["title"] == video_data[:title]
    puts "Video data unchanged"
    return false
  end

  File.write(VIDEO_DATA_PATH, JSON.pretty_generate(video_data))
  puts "Saved video data to #{VIDEO_DATA_PATH}"
  puts "  Poster URL: #{video_data[:poster_url] || '(none)'}"
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

  # Sync video metadata from Planning Center and get plan matches
  video_plan_matches = sync_video_metadata(recordings)

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

  # Get the matching plan for the latest video
  matching_plan = video_plan_matches[video_id]

  # Update the live.astro file
  astro_updated = update_live_astro(video_id)

  # Save video data with poster URL
  data_updated = save_video_data(video_id, latest, matching_plan)

  if astro_updated || data_updated
    puts "\nSuccessfully updated video data"
  else
    puts "\nNo changes needed"
  end
end

main
