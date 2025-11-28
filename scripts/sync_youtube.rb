#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync latest video and scheduled streams from YouTube
# Uses the public YouTube RSS feed (no API key required)
# Usage: ruby sync_youtube.rb

require "bundler/setup"
require "json"
require "net/http"
require "uri"
require "time"
require "openssl"

# Set timezone to Central Time
ENV['TZ'] = 'America/Chicago'

# Force immediate output
$stdout.sync = true
$stderr.sync = true

# YouTube channel ID for River of Life - Henry
CHANNEL_ID = "UCh7sGdfticWqBCIFSqhZcwQ"
CHANNEL_HANDLE = "@rol-henry"
OUTPUT_PATH = File.join(__dir__, "..", "src", "data", "youtube.json")

def fetch_rss_feed
  url = URI("https://www.youtube.com/feeds/videos.xml?channel_id=#{CHANNEL_ID}")

  http = Net::HTTP.new(url.host, url.port)
  http.use_ssl = true
  http.open_timeout = 10
  http.read_timeout = 30

  # Try with default certificates first, fall back to less strict verification for CRL issues
  [OpenSSL::SSL::VERIFY_PEER, OpenSSL::SSL::VERIFY_NONE].each do |verify_mode|
    begin
      http.verify_mode = verify_mode
      request = Net::HTTP::Get.new(url)
      request["User-Agent"] = "ROL-Website-Sync/1.0"
      response = http.request(request)

      if response.code.to_i == 200
        return response.body
      else
        puts "ERROR: HTTP #{response.code} fetching YouTube feed"
        return nil
      end
    rescue OpenSSL::SSL::SSLError => e
      puts "INFO: SSL error with verify_mode #{verify_mode}, trying fallback..." if verify_mode == OpenSSL::SSL::VERIFY_PEER
      next
    end
  end

  puts "ERROR: Failed to fetch YouTube feed after all attempts"
  nil
rescue => e
  puts "ERROR: Failed to fetch YouTube feed: #{e.message}"
  nil
end

def parse_videos(xml_content)
  videos = []

  # Simple regex parsing for YouTube RSS feed
  # Each entry has: yt:videoId, title, link, published, updated, media:group with thumbnail

  entries = xml_content.scan(/<entry>(.*?)<\/entry>/m)

  entries.each do |entry_match|
    entry = entry_match[0]

    video_id = entry[/<yt:videoId>([^<]+)<\/yt:videoId>/, 1]
    title = entry[/<title>([^<]+)<\/title>/, 1]
    published = entry[/<published>([^<]+)<\/published>/, 1]
    updated = entry[/<updated>([^<]+)<\/updated>/, 1]

    # Get thumbnail URL from media:group
    thumbnail = entry[/<media:thumbnail url="([^"]+)"/, 1]

    # Get description from media:description
    description = entry[/<media:description>([^<]*)<\/media:description>/m, 1] || ""

    next unless video_id && title

    # Decode HTML entities in title
    title = title.gsub("&amp;", "&").gsub("&lt;", "<").gsub("&gt;", ">").gsub("&quot;", '"').gsub("&#39;", "'")

    videos << {
      id: video_id,
      title: title,
      published: published,
      updated: updated,
      thumbnail: thumbnail || "https://i.ytimg.com/vi/#{video_id}/hqdefault.jpg",
      description: description.strip[0..200]
    }
  end

  videos
end

def sync_youtube
  puts "INFO: Fetching YouTube feed for channel #{CHANNEL_ID}"

  xml_content = fetch_rss_feed
  return false unless xml_content

  videos = parse_videos(xml_content)

  if videos.empty?
    puts "WARNING: No videos found in YouTube feed"
    return false
  end

  puts "SUCCESS: Found #{videos.length} videos"

  # The first video is the most recent
  latest_video = videos.first
  puts "INFO: Latest video: #{latest_video[:title]} (#{latest_video[:id]})"

  # Write YouTube data JSON
  data_dir = File.dirname(OUTPUT_PATH)
  Dir.mkdir(data_dir) unless Dir.exist?(data_dir)

  data = {
    updated_at: Time.now.iso8601,
    channel_id: CHANNEL_ID,
    channel_handle: CHANNEL_HANDLE,
    latest_video: latest_video,
    recent_videos: videos.first(5) # Keep 5 most recent
  }

  File.write(OUTPUT_PATH, JSON.pretty_generate(data))
  puts "INFO: Generated youtube.json"

  true
rescue => e
  puts "ERROR syncing YouTube: #{e.message}"
  puts e.backtrace.first(5).join("\n")
  false
end

if __FILE__ == $0
  puts "Syncing from YouTube..."
  success = sync_youtube
  if success
    puts "Done!"
    exit 0
  else
    puts "Failed to sync YouTube data"
    exit 1
  end
end
