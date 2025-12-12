#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Sync Reviews from Google and Facebook
# ==============================================================================
#
# Purpose:
#   Fetches reviews from Google Places API and Facebook Page Recommendations
#   to display social proof on the website. Captures full metadata including
#   author photos, ratings, profile links, and review text.
#
# Usage:
#   ruby sync_reviews.rb
#   bundle exec ruby sync_reviews.rb
#
# Output Files:
#   src/data/reviews.json - All review data with full metadata
#
# How It Works:
#   1. Fetches reviews from Google Places API (up to 5 most recent)
#   2. Fetches recommendations from Facebook Page API
#   3. Merges with existing manually-added reviews (preserves featured status)
#   4. Saves to reviews.json with timestamps
#
# Google Places API Limitations:
#   - Returns maximum 5 most recent reviews per request
#   - Author photos require additional fetch (profile photo URL)
#   - Review text may be truncated (full text not always available)
#
# Facebook API Limitations:
#   - Page Recommendations API requires page token
#   - Only shows recommendation percentage, not individual reviews publicly
#   - Individual review text requires reviewer permission
#
# Environment Variables:
#   GOOGLE_PLACES_API_KEY    - Google Cloud API key with Places API enabled
#   GOOGLE_PLACE_ID          - Place ID for River of Life church
#   FB_PAGE_ID               - Facebook Page ID
#   FB_PAGE_ACCESS_TOKEN     - Facebook Page Access Token
#
# ==============================================================================

require "bundler/setup"
Bundler.require(:default)

require "json"
require "net/http"
require "uri"
require "time"

# Set timezone to Central Time
ENV['TZ'] = 'America/Chicago'

# Force immediate output
$stdout.sync = true
$stderr.sync = true

# Configuration
GOOGLE_PLACES_API_KEY = ENV["GOOGLE_PLACES_API_KEY"]
GOOGLE_PLACE_ID = ENV["GOOGLE_PLACE_ID"] || "ChIJE3ycD39tzYgR0koZwg9JyQw" # River of Life church
FB_PAGE_ID = ENV["FB_PAGE_ID"] || "147553505345372"
FB_PAGE_ACCESS_TOKEN = ENV["FB_PAGE_ACCESS_TOKEN"]

# File paths
DATA_FILE = File.join(__dir__, "..", "src", "data", "reviews.json")

class ReviewSync
  def initialize
    @errors = []
    @google_reviews = []
    @facebook_data = nil
  end

  def run
    puts "INFO: Starting reviews sync..."
    puts ""

    # Load existing data to preserve manual entries
    existing_data = load_existing_data

    # Fetch from Google Places API
    if GOOGLE_PLACES_API_KEY
      fetch_google_reviews
    else
      puts "WARN: GOOGLE_PLACES_API_KEY not set, skipping Google reviews"
      puts "      To enable: Set GOOGLE_PLACES_API_KEY in GitHub secrets"
    end

    # Fetch from Facebook
    if FB_PAGE_ACCESS_TOKEN
      fetch_facebook_data
    else
      puts "WARN: FB_PAGE_ACCESS_TOKEN not set, skipping Facebook data"
    end

    # Merge and save
    save_reviews(existing_data)

    if @errors.any?
      puts ""
      puts "ERRORS:"
      @errors.each { |e| puts "  - #{e}" }
    end

    puts ""
    puts "SUCCESS: Reviews sync complete!"
    @errors.empty?
  end

  private

  def load_existing_data
    return nil unless File.exist?(DATA_FILE)
    JSON.parse(File.read(DATA_FILE))
  rescue => e
    puts "WARN: Could not load existing reviews: #{e.message}"
    nil
  end

  def fetch_google_reviews
    puts "INFO: Fetching Google reviews..."

    # Use Places API (New) - Place Details endpoint
    # Fields: reviews (includes author, rating, text, time, etc.)
    uri = URI("https://places.googleapis.com/v1/places/#{GOOGLE_PLACE_ID}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri.request_uri)
    request["X-Goog-Api-Key"] = GOOGLE_PLACES_API_KEY
    request["X-Goog-FieldMask"] = "displayName,rating,userRatingCount,reviews"

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      # Try legacy API format
      fetch_google_reviews_legacy
      return
    end

    data = JSON.parse(response.body)

    if data["error"]
      puts "ERROR: Google Places API: #{data.dig('error', 'message')}"
      @errors << "Google Places API: #{data.dig('error', 'message')}"
      return
    end

    # Extract summary data
    @google_summary = {
      rating: data["rating"],
      total_reviews: data["userRatingCount"],
      reviews_url: "https://www.google.com/maps/place/?q=place_id:#{GOOGLE_PLACE_ID}"
    }

    puts "  Rating: #{@google_summary[:rating]} (#{@google_summary[:total_reviews]} reviews)"

    # Process reviews
    reviews = data["reviews"] || []
    puts "  Found #{reviews.length} reviews from API"

    reviews.each do |review|
      @google_reviews << {
        id: "google_#{generate_review_id(review)}",
        source: "google",
        author: {
          name: review.dig("authorAttribution", "displayName"),
          profile_url: review.dig("authorAttribution", "uri"),
          photo_url: review.dig("authorAttribution", "photoUri"),
          is_local_guide: false, # New API doesn't include this
          review_count: nil,
          photo_count: nil
        },
        rating: review["rating"],
        text: truncate_text(review.dig("text", "text") || review.dig("originalText", "text"), 150),
        full_text: review.dig("text", "text") || review.dig("originalText", "text"),
        date: parse_google_date(review["publishTime"]),
        relative_time: review["relativePublishTimeDescription"],
        review_url: nil, # Individual review URLs not available
        featured: false
      }
    end

    puts "  Processed #{@google_reviews.length} Google reviews"
  rescue => e
    puts "ERROR: Google Places API failed: #{e.message}"
    @errors << "Google Places API: #{e.message}"
  end

  def fetch_google_reviews_legacy
    puts "INFO: Trying legacy Google Places API..."

    uri = URI("https://maps.googleapis.com/maps/api/place/details/json")
    params = {
      place_id: GOOGLE_PLACE_ID,
      fields: "name,rating,user_ratings_total,reviews",
      key: GOOGLE_PLACES_API_KEY
    }
    uri.query = URI.encode_www_form(params)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      puts "ERROR: Google Places API HTTP #{response.code}"
      @errors << "Google Places API: HTTP #{response.code}"
      return
    end

    data = JSON.parse(response.body)

    if data["status"] != "OK"
      puts "ERROR: Google Places API: #{data['status']} - #{data['error_message']}"
      @errors << "Google Places API: #{data['status']}"
      return
    end

    result = data["result"]

    @google_summary = {
      rating: result["rating"],
      total_reviews: result["user_ratings_total"],
      reviews_url: "https://www.google.com/maps/place/?q=place_id:#{GOOGLE_PLACE_ID}"
    }

    puts "  Rating: #{@google_summary[:rating]} (#{@google_summary[:total_reviews]} reviews)"

    reviews = result["reviews"] || []
    puts "  Found #{reviews.length} reviews from API"

    reviews.each do |review|
      @google_reviews << {
        id: "google_#{generate_review_id_legacy(review)}",
        source: "google",
        author: {
          name: review["author_name"],
          profile_url: review["author_url"],
          photo_url: review["profile_photo_url"],
          is_local_guide: review["author_url"]&.include?("/LocalGuides/") || false,
          review_count: nil,
          photo_count: nil
        },
        rating: review["rating"],
        text: truncate_text(review["text"], 150),
        full_text: review["text"],
        date: review["time"] ? Time.at(review["time"]).strftime("%Y-%m-%d") : nil,
        relative_time: review["relative_time_description"],
        review_url: nil,
        featured: false
      }
    end

    puts "  Processed #{@google_reviews.length} Google reviews"
  rescue => e
    puts "ERROR: Legacy Google Places API failed: #{e.message}"
    @errors << "Legacy Google Places API: #{e.message}"
  end

  def fetch_facebook_data
    puts "INFO: Fetching Facebook page data..."

    # Get page token first
    page_token = get_facebook_page_token
    return unless page_token

    # Fetch page ratings data
    uri = URI("https://graph.facebook.com/v18.0/#{FB_PAGE_ID}")
    params = {
      fields: "overall_star_rating,rating_count,fan_count",
      access_token: page_token
    }
    uri.query = URI.encode_www_form(params)

    response = make_facebook_request(uri)
    return unless response

    data = JSON.parse(response)

    if data["error"]
      puts "ERROR: Facebook API: #{data.dig('error', 'message')}"
      @errors << "Facebook API: #{data.dig('error', 'message')}"
      return
    end

    # Facebook uses recommendations now (yes/no) rather than star ratings
    # The overall_star_rating may not be available
    @facebook_data = {
      rating: data["overall_star_rating"],
      rating_count: data["rating_count"],
      fan_count: data["fan_count"],
      reviews_url: "https://www.facebook.com/rolhenry/reviews"
    }

    if @facebook_data[:rating]
      puts "  Rating: #{@facebook_data[:rating]} (#{@facebook_data[:rating_count]} ratings)"
    else
      puts "  No star rating available (Facebook uses recommendations)"
      # Try to get recommendation percentage
      fetch_facebook_recommendations(page_token)
    end
  rescue => e
    puts "ERROR: Facebook API failed: #{e.message}"
    @errors << "Facebook API: #{e.message}"
  end

  def get_facebook_page_token
    uri = URI("https://graph.facebook.com/v18.0/me/accounts")
    params = { access_token: FB_PAGE_ACCESS_TOKEN }
    uri.query = URI.encode_www_form(params)

    response = make_facebook_request(uri)
    return nil unless response

    data = JSON.parse(response)

    if data["error"]
      puts "ERROR: Facebook auth: #{data.dig('error', 'message')}"
      @errors << "Facebook auth: #{data.dig('error', 'message')}"
      return nil
    end

    pages = data["data"] || []
    page = pages.find { |p| p["id"] == FB_PAGE_ID }

    unless page
      puts "WARN: Could not find page #{FB_PAGE_ID}"
      return nil
    end

    page["access_token"]
  end

  def fetch_facebook_recommendations(page_token)
    # Facebook Page recommendations endpoint
    uri = URI("https://graph.facebook.com/v18.0/#{FB_PAGE_ID}/ratings")
    params = {
      access_token: page_token,
      limit: 100
    }
    uri.query = URI.encode_www_form(params)

    response = make_facebook_request(uri)
    return unless response

    data = JSON.parse(response)

    if data["error"]
      # Recommendations may require special permissions
      puts "  Note: Cannot fetch individual recommendations (requires permissions)"
      return
    end

    ratings = data["data"] || []
    if ratings.any?
      recommends = ratings.count { |r| r["recommendation_type"] == "positive" }
      total = ratings.length
      @facebook_data[:recommendation_percent] = total > 0 ? ((recommends.to_f / total) * 100).round : nil
      puts "  Recommendations: #{recommends}/#{total} (#{@facebook_data[:recommendation_percent]}%)"
    end
  rescue => e
    puts "  Note: Could not fetch recommendations: #{e.message}"
  end

  def make_facebook_request(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE # FB has CRL issues
    http.open_timeout = 30
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)

    case response
    when Net::HTTPSuccess
      response.body
    else
      puts "ERROR: Facebook HTTP #{response.code}"
      nil
    end
  rescue => e
    puts "ERROR: Facebook request failed: #{e.message}"
    nil
  end

  def save_reviews(existing_data)
    puts ""
    puts "INFO: Saving reviews..."

    # Start with existing manual reviews
    existing_reviews = existing_data&.dig("reviews") || []

    # Build new reviews list
    new_reviews = []

    # Add Google reviews (update existing or add new)
    @google_reviews.each do |review|
      existing = existing_reviews.find { |r| r["id"] == review[:id] }
      if existing
        # Preserve featured status from existing
        review[:featured] = existing["featured"] || false
      end
      new_reviews << review
    end

    # Keep manual reviews that aren't from Google API
    existing_reviews.each do |review|
      # Keep reviews that are manually added (don't have google_ prefix from API fetch)
      # or that weren't found in this sync
      unless new_reviews.any? { |r| r[:id] == review["id"] }
        # This is either a manual review or an old Google review not in current API response
        # Keep it as long as it's marked featured or is manual
        if review["featured"] || !review["id"]&.start_with?("google_")
          new_reviews << symbolize_keys(review)
        end
      end
    end

    # Sort: featured first, then by date (newest first)
    new_reviews.sort_by! do |r|
      [
        r[:featured] ? 0 : 1,
        r[:date] ? -Time.parse(r[:date]).to_i : 0
      ]
    end

    # Build summary
    summary = {
      google: @google_summary || existing_data&.dig("summary", "google"),
      facebook: {
        recommendation_percent: @facebook_data&.dig(:recommendation_percent) || existing_data&.dig("summary", "facebook", "recommendation_percent"),
        reviews_url: "https://www.facebook.com/rolhenry/reviews"
      }
    }

    # Build final data structure
    output = {
      updated_at: Time.now.iso8601,
      summary: deep_stringify_keys(summary),
      reviews: new_reviews.map { |r| deep_stringify_keys(r) }
    }

    File.write(DATA_FILE, JSON.pretty_generate(output))
    puts "  Saved #{new_reviews.length} reviews to reviews.json"
    puts "  Google: #{@google_reviews.length} from API"
    puts "  Manual/existing: #{new_reviews.length - @google_reviews.length}"
  end

  # Helper methods

  def generate_review_id(review)
    # Create stable ID from author name and publish time
    author = review.dig("authorAttribution", "displayName") || "unknown"
    time = review["publishTime"] || ""
    Digest::MD5.hexdigest("#{author}_#{time}")[0..7]
  end

  def generate_review_id_legacy(review)
    author = review["author_name"] || "unknown"
    time = review["time"] || 0
    Digest::MD5.hexdigest("#{author}_#{time}")[0..7]
  end

  def parse_google_date(publish_time)
    return nil unless publish_time
    Time.parse(publish_time).strftime("%Y-%m-%d")
  rescue
    nil
  end

  def truncate_text(text, length)
    return "" unless text
    return text if text.length <= length
    text[0...length].gsub(/\s+\S*$/, '') + "..."
  end

  def symbolize_keys(hash)
    return hash unless hash.is_a?(Hash)
    hash.transform_keys(&:to_sym).transform_values do |v|
      v.is_a?(Hash) ? symbolize_keys(v) : v
    end
  end

  def deep_stringify_keys(obj)
    case obj
    when Hash
      obj.transform_keys(&:to_s).transform_values { |v| deep_stringify_keys(v) }
    when Array
      obj.map { |v| deep_stringify_keys(v) }
    else
      obj
    end
  end
end

if __FILE__ == $0
  require 'digest'

  puts "Reviews Sync for River of Life Church"
  puts "======================================"
  puts ""

  sync = ReviewSync.new
  success = sync.run

  exit(success ? 0 : 1)
end
