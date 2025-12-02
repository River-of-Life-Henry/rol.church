#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync latest Sunday service video data from Cloudflare Stream
# Usage: ruby sync_cloudflare_video.rb
#
# This script fetches recordings from the Cloudflare Stream Live Input
# and finds the most recent SUNDAY service recording to display on the
# Watch Live page when not streaming live.
#
# It also fetches Planning Center service plan data to get series artwork
# for the video poster image.
#
# NOTE: Video title updates in Cloudflare are handled by pco-streaming-sync.
# This script only READS from Cloudflare and updates local files.
#
# Environment variables required:
#   CLOUDFLARE_ACCOUNT_ID - Cloudflare account ID
#   CLOUDFLARE_API_TOKEN - Cloudflare API token with Stream read access
#   ROL_PLANNING_CENTER_CLIENT_ID - Planning Center API client ID
#   ROL_PLANNING_CENTER_SECRET - Planning Center API secret
#
# The script updates:
#   - src/pages/live.astro (CLOUDFLARE_LATEST_VIDEO_ID constant)
#   - src/data/cloudflare_video.json (video metadata including poster URL)

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

def fetch_service_plan_for_date(video_date)
  pco = PCO::Client.api
  series_cache = {}

  begin
    service_types = pco.services.v2.service_types.get

    service_types["data"].each do |service_type|
      service_type_id = service_type["id"]
      service_type_name = service_type["attributes"]["name"]

      type_plans = pco.services.v2.service_types[service_type_id].plans.get(
        per_page: 10,
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

      type_plans["data"].each do |plan|
        sort_date = plan["attributes"]["sort_date"]
        next unless sort_date

        plan_date = Date.parse(sort_date)

        if plan_date == video_date
          series_id = plan.dig("relationships", "series", "data", "id")
          series_info = series_id ? series_cache[series_id] : nil

          return {
            id: plan["id"],
            title: plan["attributes"]["title"],
            series_title: plan["attributes"]["series_title"],
            series_artwork_url: series_info&.dig(:artwork_url),
            dates: plan["attributes"]["dates"],
            date: plan_date,
            service_type_id: service_type_id,
            service_type_name: service_type_name
          }
        end
      end
    end
  rescue => e
    puts "  ERROR fetching plans: #{e.message}"
  end

  nil
end

def find_latest_sunday_recording(recordings)
  ready_recordings = recordings.select { |r| r["status"]&.dig("state") == "ready" }

  if ready_recordings.empty?
    puts "No ready recordings found"
    return nil
  end

  sunday_recordings = ready_recordings.select do |recording|
    created_at = Time.parse(recording["created"])
    created_at.wday == 0 && created_at.hour >= 10
  end

  if sunday_recordings.empty?
    puts "No Sunday recordings found, using most recent recording"
    return ready_recordings.max_by { |r| Time.parse(r["created"]) }
  end

  sunday_recordings.max_by { |r| Time.parse(r["created"]) }
end

def build_title(video, matching_plan)
  if matching_plan
    date_prefix = matching_plan[:date].strftime("%-m/%-d/%Y")
    plan_title = matching_plan[:title]&.strip

    if plan_title.nil? || plan_title.empty?
      "#{date_prefix}: #{matching_plan[:service_type_name]}"
    else
      "#{date_prefix}: #{plan_title} - #{matching_plan[:service_type_name]}"
    end
  else
    video.dig("publicDetails", "title") || "Sunday Service"
  end
end

def update_live_astro(video_id)
  unless File.exist?(LIVE_ASTRO_PATH)
    puts "ERROR: #{LIVE_ASTRO_PATH} not found"
    exit 1
  end

  content = File.read(LIVE_ASTRO_PATH)

  updated_content = content.gsub(
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
    title: build_title(video, matching_plan),
    created: video["created"],
    duration: video["duration"],
    thumbnail: video["thumbnail"],
    poster_url: matching_plan&.dig(:series_artwork_url),
    series_title: matching_plan&.dig(:series_title),
    plan_title: matching_plan&.dig(:title),
    service_type: matching_plan&.dig(:service_type_name),
    updated_at: Time.now.utc.iso8601
  }

  FileUtils.mkdir_p(File.dirname(VIDEO_DATA_PATH))

  existing_data = if File.exist?(VIDEO_DATA_PATH)
    JSON.parse(File.read(VIDEO_DATA_PATH))
  else
    {}
  end

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
  puts "Syncing Cloudflare Stream video data..."
  puts "-" * 40

  unless CLOUDFLARE_API_TOKEN
    puts "ERROR: CLOUDFLARE_API_TOKEN environment variable not set"
    puts "Set this in GitHub Actions secrets or in scripts/.env for local development"
    exit 1
  end

  puts "Fetching recordings from Cloudflare Stream..."
  recordings = fetch_recordings
  puts "Found #{recordings.length} total recordings"

  latest = find_latest_sunday_recording(recordings)

  if latest.nil?
    puts "No suitable recording found"
    exit 0
  end

  video_id = latest["uid"]
  created_at = Time.parse(latest["created"])
  video_date = created_at.to_date
  duration = latest["duration"] || 0
  duration_str = "#{(duration / 60).to_i}m #{(duration % 60).to_i}s"

  puts "\nLatest Sunday recording:"
  puts "  Video ID: #{video_id}"
  puts "  Created: #{created_at.strftime('%A, %B %d, %Y at %I:%M %p %Z')}"
  puts "  Duration: #{duration_str}"

  # Fetch matching Planning Center plan for poster URL
  puts "\nFetching Planning Center plan for #{video_date}..."
  matching_plan = fetch_service_plan_for_date(video_date)

  if matching_plan
    puts "  Found: #{matching_plan[:title]} (#{matching_plan[:service_type_name]})"
    puts "  Series: #{matching_plan[:series_title] || '(none)'}"
  else
    puts "  No matching plan found"
  end

  astro_updated = update_live_astro(video_id)
  data_updated = save_video_data(video_id, latest, matching_plan)

  if astro_updated || data_updated
    puts "\nSuccessfully updated video data"
  else
    puts "\nNo changes needed"
  end
end

main
