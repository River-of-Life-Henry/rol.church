#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Sync Photos from Facebook Page
# ==============================================================================
#
# Purpose:
#   Automatically discovers and syncs high-quality congregation photos from
#   Facebook page posts to the website hero slider. Uses AI to select only
#   photos with multiple smiling people (no screenshots, slides, or text).
#
# Usage:
#   ruby sync_facebook_photos.rb
#   bundle exec ruby sync_facebook_photos.rb
#
# Output Files:
#   public/hero/fb_*.jpg              - Qualifying photos (smart-cropped)
#   public/hero/fb_*.webp             - WebP versions
#   src/data/facebook_sync_state.json - Sync state (last sync, uploaded IDs)
#   src/data/hero_images.json         - Updated with new slider images
#
# How It Works:
#   1. Fetches photos from Facebook page posts (last 2 years or since last sync)
#   2. Skips already-synced photos (tracked by post ID) - saves AWS API costs
#   3. Analyzes each NEW photo with AWS Rekognition:
#      - Detects faces and smile confidence
#      - Detects text (rejects screenshots/slides)
#   4. Qualifies photos meeting criteria:
#      - ≥3 people detected
#      - ≥1 smiling OR ≥60% smiling
#      - ≤3 text elements (filters out graphics/slides)
#   5. Smart crops to 16:9 with faces at 1/3 from top
#   6. Uploads ALL qualifying photos to Planning Center Media (no limit)
#   7. Website slider displays only the 5 most recent (see HeroSlider.astro)
#
# Important: This script NEVER deletes images from Planning Center. All
# qualifying photos are uploaded and preserved in PCO for archival.
#
# AWS Rekognition Privacy Note:
#   Images are sent to AWS Rekognition API for face/text detection.
#   AWS does NOT store images after processing (stateless API).
#   No image data is used for AWS model training.
#   See: https://docs.aws.amazon.com/rekognition/latest/dg/data-privacy.html
#
# Deletion Tracking:
#   If you manually delete a fb_*.jpg from public/hero/, the script will
#   detect this and mark the post ID as "deleted" so it won't re-sync.
#
# Performance:
#   - Analyzes photos in parallel (4 threads)
#   - Saves photos in parallel (4 threads)
#   - Skips duplicates before API calls to save costs
#   - Typical runtime: 30-120 seconds (depends on new photo count)
#
# Environment Variables:
#   FB_PAGE_ID                         - Facebook Page ID
#   FB_PAGE_ACCESS_TOKEN               - Facebook System User Token
#   AWS_ACCESS_KEY_ID                  - AWS credentials for Rekognition
#   AWS_SECRET_ACCESS_KEY              - AWS credentials for Rekognition
#   AWS_REGION                         - AWS region (default: us-east-1)
#   ROL_PLANNING_CENTER_CLIENT_ID      - For uploading to PCO Media
#   ROL_PLANNING_CENTER_SECRET         - For uploading to PCO Media
#   PCO_WEBSITE_HERO_MEDIA_ID          - PCO Media ID for hero images
#
# ==============================================================================

require_relative "image_utils"
require_relative "pco_client"
require "json"
require "net/http"
require "uri"
require "openssl"
require "time"
require "fileutils"
require "set"
require "securerandom"
require "parallel"

# Set timezone to Central Time
ENV['TZ'] = 'America/Chicago'

# Force immediate output
$stdout.sync = true
$stderr.sync = true

# Configuration
FB_PAGE_ID = ENV["FB_PAGE_ID"] || "147553505345372"
FB_PAGE_ACCESS_TOKEN = ENV["FB_PAGE_ACCESS_TOKEN"]
AWS_REGION = ENV["AWS_REGION"] || "us-east-1"
PCO_MEDIA_ID = ENV["PCO_WEBSITE_HERO_MEDIA_ID"]

# Website URL for hosted images
SITE_URL = "https://rol.church"

# Directories and files
HERO_DIR = File.join(__dir__, "..", "public", "hero")
DATA_FILE = File.join(__dir__, "..", "src", "data", "hero_images.json")
STATE_FILE = File.join(__dir__, "..", "src", "data", "facebook_sync_state.json")
TEMP_DIR = File.join(__dir__, "..", ".fb_temp")
REKOGNITION_DATA_DIR = File.join(__dir__, "rekognition_data")
REKOGNITION_PHOTOS_DIR = File.join(REKOGNITION_DATA_DIR, "photos")

# Photo qualification thresholds
MIN_PEOPLE = 3  # Require at least 3 people in the photo
MIN_SMILING_PEOPLE = 1  # At least 1 person smiling
MIN_SMILE_PERCENTAGE = 0.6  # OR at least 60% of people smiling
SMILE_CONFIDENCE_THRESHOLD = 60  # Rekognition confidence threshold for smile detection
MAX_TEXT_DETECTIONS = 10  # Reject photos with more than this many text elements (screenshots, slides)

# Lookback period for initial sync (2 years)
LOOKBACK_YEARS = 2

# Parallel processing threads
PARALLEL_THREADS = 4

class FacebookPhotoSync
  def initialize
    @errors = []
    validate_environment!
    init_aws_client!
  end

  def validate_environment!
    missing = []
    missing << "FB_PAGE_ACCESS_TOKEN" unless FB_PAGE_ACCESS_TOKEN

    unless missing.empty?
      puts "ERROR: Missing required environment variables: #{missing.join(', ')}"
      puts ""
      puts "Setup instructions:"
      puts "1. Set FB_PAGE_ACCESS_TOKEN to your Facebook System User Token"
      puts "2. Configure AWS credentials via 'aws configure' or environment variables"
      puts ""
      exit 1
    end

    # Get page token from the system user token
    @page_token = get_page_token
  end

  def get_page_token
    puts "INFO: Getting page access token..."

    uri = URI("https://graph.facebook.com/v18.0/me/accounts?access_token=#{FB_PAGE_ACCESS_TOKEN}")
    response = make_request(uri)

    unless response
      puts "ERROR: Could not authenticate with Facebook"
      exit 1
    end

    data = JSON.parse(response)

    if data["error"]
      puts "ERROR: Facebook API error: #{data["error"]["message"]}"
      exit 1
    end

    pages = data["data"] || []
    page = pages.find { |p| p["id"] == FB_PAGE_ID }

    unless page
      puts "ERROR: Could not find page #{FB_PAGE_ID} in accessible pages"
      puts "Available pages: #{pages.map { |p| "#{p['name']} (#{p['id']})" }.join(', ')}"
      exit 1
    end

    puts "INFO: Got page token for #{page['name']}"
    page["access_token"]
  end

  def init_aws_client!
    begin
      require 'aws-sdk-rekognition'
      @rekognition = Aws::Rekognition::Client.new(
        region: AWS_REGION,
        ssl_verify_peer: false  # Workaround for CRL issues on some systems
      )
      puts "INFO: AWS Rekognition client initialized (region: #{AWS_REGION})"
      puts "INFO: Note: Images are processed but NOT stored by AWS Rekognition"
    rescue LoadError
      puts "ERROR: aws-sdk-rekognition gem not installed"
      puts "Run: bundle add aws-sdk-rekognition"
      exit 1
    rescue Aws::Errors::MissingCredentialsError
      puts "ERROR: AWS credentials not configured"
      puts "Run 'aws configure' or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
      exit 1
    end
  end

  def run
    puts "INFO: Starting Facebook photo sync..."

    # Create directories
    FileUtils.mkdir_p(TEMP_DIR)
    FileUtils.mkdir_p(HERO_DIR)
    FileUtils.mkdir_p(REKOGNITION_PHOTOS_DIR)

    # Load last sync state (also loads @uploaded_post_ids and @deleted_post_ids)
    @uploaded_post_ids ||= Set.new
    @deleted_post_ids ||= Set.new
    @newly_uploaded_ids = []
    last_sync = load_state

    # Load existing hero images to avoid duplicates
    @existing_images = load_existing_images
    puts "INFO: Found #{@existing_images.length} existing hero images"
    puts "INFO: Tracking #{@uploaded_post_ids.length} previously synced post IDs"
    puts "INFO: Tracking #{@deleted_post_ids.length} deleted post IDs (will not re-sync)" if @deleted_post_ids.length > 0

    # Fetch photos from Facebook posts
    photos = fetch_facebook_photos(last_sync)
    puts "INFO: Found #{photos.length} photos to analyze"

    if photos.empty?
      puts "INFO: No new photos to process"
      cleanup
      return true
    end

    # Filter out already synced photos first (save API costs)
    photos_to_analyze = []
    skipped_duplicates = 0
    photos.each do |photo|
      if already_synced?(photo)
        skipped_duplicates += 1
      else
        photos_to_analyze << photo
      end
    end

    puts "INFO: #{photos_to_analyze.length} photos to analyze (#{skipped_duplicates} duplicates skipped)"

    # Analyze photos in parallel for speed
    mutex = Mutex.new
    qualifying_photos = []

    if photos_to_analyze.any?
      puts "INFO: Analyzing #{photos_to_analyze.length} photos in parallel (#{PARALLEL_THREADS} threads)..."

      Parallel.each_with_index(photos_to_analyze, in_threads: PARALLEL_THREADS) do |photo, index|
        result = analyze_photo(photo)

        mutex.synchronize do
          if result[:qualifies]
            puts "  ✓ [#{index + 1}/#{photos_to_analyze.length}] Photo qualifies: #{result[:smiling_count]} smiling out of #{result[:total_people]} people"
            qualifying_photos << photo.merge(analysis: result)
          else
            puts "  ✗ [#{index + 1}/#{photos_to_analyze.length}] #{result[:reason]}"
          end
        end
      end
    end

    puts "INFO: #{qualifying_photos.length} photos qualify for saving"

    # Save qualifying photos to public/hero/ (parallel processing)
    saved_count = 0
    new_images = []

    if qualifying_photos.any?
      puts "INFO: Saving #{qualifying_photos.length} photos in parallel (#{PARALLEL_THREADS} threads)..."

      results = Parallel.map_with_index(qualifying_photos, in_threads: PARALLEL_THREADS) do |photo, index|
        result = save_photo(photo)

        mutex.synchronize do
          if result
            puts "  ✓ [#{index + 1}/#{qualifying_photos.length}] Saved: #{result[:filename]}"
          else
            puts "  ✗ [#{index + 1}/#{qualifying_photos.length}] Save failed"
          end
        end

        { photo: photo, result: result }
      end

      # Collect results
      results.each do |r|
        if r[:result]
          saved_count += 1
          new_images << r[:result]
          @newly_uploaded_ids << r[:photo]['id']
        end
      end
    end

    # Update hero_images.json
    if new_images.any?
      update_hero_images_json(new_images)
    end

    # Save sync state
    save_state

    # Cleanup
    cleanup

    puts ""
    puts "SUCCESS: Sync complete!"
    puts "  - Photos analyzed: #{photos.length}"
    puts "  - Photos qualifying: #{qualifying_photos.length}"
    puts "  - Photos saved: #{saved_count}"

    true
  rescue => e
    puts "ERROR: #{e.message}"
    puts e.backtrace.first(5).join("\n")
    cleanup
    false
  end

  private

  def load_state
    return nil unless File.exist?(STATE_FILE)

    state = JSON.parse(File.read(STATE_FILE))
    @uploaded_post_ids = Set.new(state["uploaded_post_ids"] || [])
    @deleted_post_ids = Set.new(state["deleted_post_ids"] || [])
    Time.parse(state["last_sync"]) rescue nil
  end

  def save_state
    # Merge newly synced post IDs with existing ones
    all_uploaded = (@uploaded_post_ids || Set.new).merge(@newly_uploaded_ids || [])

    # Detect deleted photos: previously uploaded but no longer on disk
    detect_deleted_photos

    File.write(STATE_FILE, JSON.pretty_generate({
      last_sync: Time.now.iso8601,
      updated_at: Time.now.iso8601,
      uploaded_post_ids: all_uploaded.to_a,
      deleted_post_ids: (@deleted_post_ids || Set.new).to_a
    }))
  end

  def detect_deleted_photos
    # Check if any previously uploaded photos have been deleted from disk
    # If so, mark them as deleted so they won't be re-synced
    @deleted_post_ids ||= Set.new

    (@uploaded_post_ids || Set.new).each do |post_id|
      # Generate what the filename would be for this post
      # We need to check if the file exists
      matching_files = Dir.glob(File.join(HERO_DIR, "fb_*_#{post_id.gsub(/[^a-zA-Z0-9]/, '_')}.jpg"))

      if matching_files.empty?
        # File was deleted - mark as deleted so we don't re-download
        @deleted_post_ids.add(post_id)
        puts "INFO: Detected deleted photo (post #{post_id}) - will not re-sync"
      end
    end
  end

  def load_existing_images
    existing = Set.new

    # Get existing filenames from hero directory
    if Dir.exist?(HERO_DIR)
      Dir.glob(File.join(HERO_DIR, "fb_*.{jpg,jpeg,webp}")).each do |path|
        existing.add(File.basename(path))
      end
    end

    existing
  end

  def generate_filename(photo)
    created_at = Time.parse(photo["created_time"]) rescue Time.now
    "fb_#{created_at.strftime('%Y%m%d')}_#{photo['id'].gsub(/[^a-zA-Z0-9]/, '_')}"
  end

  def already_synced?(photo)
    # Check if this photo was deleted by user - never re-sync deleted photos
    return true if @deleted_post_ids&.include?(photo['id'])
    # Check if this photo's post ID was previously synced (tracked in state file)
    return true if @uploaded_post_ids&.include?(photo['id'])
    # Also check the generated filename against existing files
    base = generate_filename(photo)
    return true if @existing_images.include?("#{base}.jpg")
    return true if @existing_images.include?("#{base}.webp")
    false
  end

  def fetch_facebook_photos(since_time)
    puts "INFO: Fetching photos from Facebook page posts..."

    # Calculate date range (last 2 years if no previous sync)
    since_time ||= Time.now - (LOOKBACK_YEARS * 365 * 24 * 60 * 60)
    since_timestamp = since_time.to_i
    puts "DEBUG: Looking for posts since #{Time.at(since_timestamp).strftime('%Y-%m-%d')}"

    photos = []
    next_url = nil

    loop do
      # Build URL for Facebook Graph API - fetch posts with photos
      if next_url
        uri = URI(next_url)
      else
        params = {
          "fields" => "id,created_time,full_picture,message",
          "since" => since_timestamp.to_s,
          "limit" => "100",
          "access_token" => @page_token
        }
        uri = URI("https://graph.facebook.com/v18.0/#{FB_PAGE_ID}/posts")
        uri.query = URI.encode_www_form(params)
      end

      puts "DEBUG: Fetching posts..."

      response = make_request(uri)

      unless response
        puts "ERROR: Failed to fetch posts from Facebook"
        break
      end

      data = JSON.parse(response)

      if data["error"]
        puts "ERROR: Facebook API error: #{data["error"]["message"]}"
        break
      end

      posts = data["data"] || []

      # Extract photos from posts that have them
      posts.each do |post|
        next unless post["full_picture"]

        photos << {
          "id" => post["id"],
          "created_time" => post["created_time"],
          "image_url" => post["full_picture"],
          "message" => post["message"]
        }
      end

      puts "DEBUG: Fetched #{posts.length} posts, #{photos.length} with photos so far"

      # Check for next page
      next_url = data.dig("paging", "next")
      break unless next_url

      # Note: No artificial limit - all qualifying photos should be uploaded to PCO
      # The website slider is limited to 5 images in HeroSlider.astro
    end

    photos
  end

  def make_request(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.open_timeout = 30
    http.read_timeout = 60

    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)

    case response
    when Net::HTTPSuccess
      response.body
    else
      puts "ERROR: HTTP #{response.code}: #{response.body[0..200]}"
      nil
    end
  rescue OpenSSL::SSL::SSLError => e
    # Retry without strict CRL checking
    puts "DEBUG: SSL error, retrying with relaxed verification..."
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.open_timeout = 30
    http.read_timeout = 60

    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)

    case response
    when Net::HTTPSuccess
      response.body
    else
      puts "ERROR: HTTP #{response.code}: #{response.body[0..200]}"
      nil
    end
  rescue => e
    puts "ERROR: Request failed: #{e.message}"
    nil
  end

  def analyze_photo(photo)
    image_url = photo["image_url"]
    return { qualifies: false, reason: "No image URL" } unless image_url

    # Download image to temp file
    safe_id = photo['id'].gsub(/[^a-zA-Z0-9]/, '_')
    temp_path = File.join(TEMP_DIR, "#{safe_id}.jpg")
    unless download_image(image_url, temp_path)
      return { qualifies: false, reason: "Failed to download" }
    end

    # Analyze with AWS Rekognition and save raw data
    analyze_with_rekognition(temp_path, photo)
  end

  def download_image(url, path)
    uri = URI(url)

    # Follow redirects with SSL handling
    5.times do
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE  # FB CDN has CRL issues
      http.open_timeout = 30
      http.read_timeout = 60

      request = Net::HTTP::Get.new(uri.request_uri)
      response = http.request(request)

      case response
      when Net::HTTPRedirection
        uri = URI(response['location'])
      when Net::HTTPSuccess
        File.binwrite(path, response.body)
        return true
      else
        puts "ERROR: Download HTTP #{response.code}"
        return false
      end
    end

    false
  rescue => e
    puts "ERROR: Download failed: #{e.message}"
    false
  end

  def analyze_with_rekognition(image_path, photo = nil)
    # Read image bytes
    image_bytes = File.binread(image_path)

    # First check for text in the image (reject screenshots, slides, etc.)
    text_response = @rekognition.detect_text({
      image: { bytes: image_bytes }
    })

    text_detections = text_response.text_detections.select { |t| t.type == "LINE" }

    # Call Rekognition DetectFaces API
    face_response = @rekognition.detect_faces({
      image: { bytes: image_bytes },
      attributes: ['ALL']  # Get all attributes including smile
    })

    faces = face_response.face_details
    total = faces.length
    smiling = 0

    faces.each do |face|
      # Check if person is smiling OR happy with confidence above threshold
      # Using both smile detection and HAPPY emotion catches more natural/subtle smiles
      smile_detected = face.smile && face.smile.value && face.smile.confidence >= SMILE_CONFIDENCE_THRESHOLD
      happy_emotion = face.emotions&.find { |e| e.type == "HAPPY" }
      happy_detected = happy_emotion && happy_emotion.confidence >= SMILE_CONFIDENCE_THRESHOLD

      if smile_detected || happy_detected
        smiling += 1
      end
    end

    # Save raw Rekognition data for later analysis
    if photo
      save_rekognition_data(photo, text_response, face_response, text_detections.length, total, smiling)
    end

    # Check text threshold after saving data
    if text_detections.length > MAX_TEXT_DETECTIONS
      return {
        qualifies: false,
        total_people: total,
        smiling_count: smiling,
        reason: "Too much text detected (#{text_detections.length} lines) - likely a screenshot or slide"
      }
    end

    # Determine if photo qualifies
    qualifies = false
    if total < MIN_PEOPLE
      reason = "Only #{total} #{total == 1 ? 'person' : 'people'} detected (need #{MIN_PEOPLE}+)"
    elsif smiling >= MIN_SMILING_PEOPLE
      qualifies = true
      reason = "Has #{smiling} smiling out of #{total} people"
    elsif total > 0 && (smiling.to_f / total) >= MIN_SMILE_PERCENTAGE
      qualifies = true
      reason = "#{(smiling.to_f / total * 100).round}% smiling (#{smiling}/#{total})"
    else
      reason = "Only #{smiling}/#{total} smiling (#{(smiling.to_f / total * 100).round}%)"
    end

    # Calculate average face center position for smart cropping
    face_boxes = faces.map { |f| f.bounding_box }

    {
      qualifies: qualifies,
      total_people: total,
      smiling_count: smiling,
      reason: reason,
      face_boxes: face_boxes
    }
  rescue Aws::Rekognition::Errors::ServiceError => e
    puts "ERROR: Rekognition error: #{e.message}"
    { qualifies: false, reason: "Rekognition error: #{e.message}" }
  rescue => e
    puts "ERROR: Analysis failed: #{e.message}"
    { qualifies: false, reason: "Analysis error: #{e.message}" }
  end

  # Save raw Rekognition output for later analysis
  def save_rekognition_data(photo, text_response, face_response, text_lines, total_people, smiling_count)
    safe_id = photo['id'].gsub(/[^a-zA-Z0-9]/, '_')

    data = {
      post_id: photo['id'],
      created_time: photo['created_time'],
      message: photo['message'],
      image_url: photo['image_url'],
      analyzed_at: Time.now.iso8601,
      summary: {
        text_lines: text_lines,
        total_people: total_people,
        smiling_count: smiling_count,
        smile_percentage: total_people > 0 ? (smiling_count.to_f / total_people * 100).round : 0
      },
      text_detection: {
        text_detections: text_response.text_detections.map do |t|
          {
            type: t.type,
            detected_text: t.detected_text,
            confidence: t.confidence,
            geometry: t.geometry ? {
              bounding_box: {
                width: t.geometry.bounding_box.width,
                height: t.geometry.bounding_box.height,
                left: t.geometry.bounding_box.left,
                top: t.geometry.bounding_box.top
              }
            } : nil
          }
        end
      },
      face_detection: {
        face_details: face_response.face_details.map do |f|
          {
            bounding_box: {
              width: f.bounding_box.width,
              height: f.bounding_box.height,
              left: f.bounding_box.left,
              top: f.bounding_box.top
            },
            age_range: f.age_range ? { low: f.age_range.low, high: f.age_range.high } : nil,
            smile: f.smile ? { value: f.smile.value, confidence: f.smile.confidence } : nil,
            gender: f.gender ? { value: f.gender.value, confidence: f.gender.confidence } : nil,
            emotions: f.emotions&.map { |e| { type: e.type, confidence: e.confidence } },
            confidence: f.confidence
          }
        end
      }
    }

    File.write(File.join(REKOGNITION_PHOTOS_DIR, "#{safe_id}.json"), JSON.pretty_generate(data))
  rescue => e
    # Don't fail the whole sync if we can't save debug data
    puts "WARN: Could not save Rekognition data for #{photo['id']}: #{e.message}"
  end

  # Smart crop image to position faces at 1/3 from top (2/3 from bottom)
  # This follows the photographic "rule of thirds" for more pleasing composition.
  # Target aspect ratio is 16:9 for hero slider images.
  #
  # Algorithm:
  #   1. Calculate average face center position from Rekognition bounding boxes
  #   2. Determine crop dimensions to achieve 16:9 aspect ratio
  #   3. If image is wider than 16:9: crop width, center on faces horizontally
  #   4. If image is taller than 16:9: crop height, position faces at 1/3 from top
  #   5. Clamp crop bounds to stay within image dimensions
  #
  # @param input_path [String] Path to original image
  # @param output_path [String] Path for cropped/optimized output
  # @param face_boxes [Array] Rekognition face bounding boxes (normalized 0-1 coords)
  def smart_crop_and_optimize(input_path, output_path, face_boxes)
    # Read image dimensions using sips
    dims = `sips -g pixelWidth -g pixelHeight "#{input_path}" 2>/dev/null`
    width = dims[/pixelWidth:\s*(\d+)/, 1].to_i
    height = dims[/pixelHeight:\s*(\d+)/, 1].to_i

    if width == 0 || height == 0
      puts "WARNING: Could not read image dimensions, using standard optimize"
      ImageUtils.optimize_image(input_path, output_path, ImageUtils::HERO_MAX_WIDTH, ImageUtils::HERO_MAX_HEIGHT)
      return
    end

    # Target aspect ratio 16:9 for hero images
    target_ratio = 16.0 / 9.0
    current_ratio = width.to_f / height

    if face_boxes.empty?
      # No faces detected, just optimize without smart crop
      puts "INFO: No face data for smart crop, using center crop"
      ImageUtils.optimize_image(input_path, output_path, ImageUtils::HERO_MAX_WIDTH, ImageUtils::HERO_MAX_HEIGHT)
      return
    end

    # Calculate average face center (Rekognition returns normalized 0-1 coordinates)
    avg_face_top = face_boxes.map { |b| b.top }.sum / face_boxes.length
    avg_face_height = face_boxes.map { |b| b.height }.sum / face_boxes.length
    avg_face_center_y = avg_face_top + (avg_face_height / 2)

    # We want faces at 1/3 from top of final image
    target_face_position = 1.0 / 3.0

    if current_ratio > target_ratio
      # Image is wider than 16:9, crop width (keep full height)
      new_width = (height * target_ratio).to_i

      # Calculate x offset to keep faces horizontally centered
      avg_face_left = face_boxes.map { |b| b.left }.sum / face_boxes.length
      avg_face_width = face_boxes.map { |b| b.width }.sum / face_boxes.length
      avg_face_center_x = avg_face_left + (avg_face_width / 2)

      # Center crop on faces horizontally
      ideal_x = (avg_face_center_x * width) - (new_width / 2)
      crop_x = [[ideal_x, 0].max, width - new_width].min.to_i
      crop_y = 0
      crop_width = new_width
      crop_height = height
    else
      # Image is taller than 16:9, crop height (keep full width)
      new_height = (width / target_ratio).to_i

      # Calculate y offset to position faces at 1/3 from top
      # Face center in pixels
      face_center_px = avg_face_center_y * height

      # Where we want the face center to be in the cropped image
      target_center_px = new_height * target_face_position

      # Calculate crop offset
      ideal_y = face_center_px - target_center_px
      crop_y = [[ideal_y, 0].max, height - new_height].min.to_i
      crop_x = 0
      crop_width = width
      crop_height = new_height
    end

    puts "INFO: Smart crop: #{width}x#{height} -> #{crop_width}x#{crop_height} @ (#{crop_x},#{crop_y})"
    puts "INFO: Face center at #{(avg_face_center_y * 100).round}% from top, targeting #{(target_face_position * 100).round}%"

    # Use sips to crop the image
    temp_cropped = input_path.sub('.jpg', '_cropped.jpg')

    # sips crop uses --cropToHeightWidth and --cropOffset
    system("sips --cropToHeightWidth #{crop_height} #{crop_width} --cropOffset #{crop_y} #{crop_x} \"#{input_path}\" --out \"#{temp_cropped}\" >/dev/null 2>&1")

    if File.exist?(temp_cropped)
      # Now optimize the cropped image
      ImageUtils.optimize_image(temp_cropped, output_path, ImageUtils::HERO_MAX_WIDTH, ImageUtils::HERO_MAX_HEIGHT)
      File.delete(temp_cropped)
    else
      puts "WARNING: Crop failed, using standard optimize"
      ImageUtils.optimize_image(input_path, output_path, ImageUtils::HERO_MAX_WIDTH, ImageUtils::HERO_MAX_HEIGHT)
    end
  end

  def save_photo(photo)
    # Get the local image path
    temp_path = File.join(TEMP_DIR, "#{photo['id'].gsub(/[^a-zA-Z0-9]/, '_')}.jpg")

    unless File.exist?(temp_path)
      puts "ERROR: Image file not found: #{temp_path}"
      return nil
    end

    # Generate consistent filename (without extension)
    base_filename = generate_filename(photo)
    jpg_filename = "#{base_filename}.jpg"
    webp_filename = "#{base_filename}.webp"

    jpg_path = File.join(HERO_DIR, jpg_filename)

    # Smart crop based on face positions, then optimize
    face_boxes = photo.dig(:analysis, :face_boxes) || []
    smart_crop_and_optimize(temp_path, jpg_path, face_boxes)

    # Generate WebP version (generate_webp automatically creates .webp from input path)
    ImageUtils.generate_webp(jpg_path)

    # Get created_time for sorting
    created_at = Time.parse(photo["created_time"]) rescue Time.now

    # Upload to Planning Center Services Media
    upload_to_pco_media(jpg_path, jpg_filename)

    {
      filename: jpg_filename,
      webp_filename: webp_filename,
      path: "/hero/#{jpg_filename}",
      webp_path: "/hero/#{webp_filename}",
      source: "facebook",
      created_at: created_at.iso8601,
      post_id: photo['id']
    }
  rescue => e
    puts "ERROR: Save failed: #{e.message}"
    nil
  end

  def upload_to_pco_media(file_path, filename)
    return unless PCO_MEDIA_ID

    # Step 1: Upload file to PCO's file upload endpoint to get a UUID
    file_uuid = upload_file_to_pco(file_path, filename)
    return unless file_uuid

    # Step 2: Create attachment in Services Media using the UUID
    create_media_attachment(file_uuid, filename)
  end

  def upload_file_to_pco(file_path, filename)
    # Upload to https://upload.planningcenteronline.com/v2/files using multipart form
    uri = URI("https://upload.planningcenteronline.com/v2/files")

    # Build multipart form data manually
    boundary = "----RubyFormBoundary#{SecureRandom.hex(16)}"
    file_data = File.binread(file_path)

    # Construct multipart body
    post_body = String.new
    post_body << "--#{boundary}\r\n"
    post_body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n"
    post_body << "Content-Type: image/jpeg\r\n"
    post_body << "\r\n"
    post_body << file_data
    post_body << "\r\n--#{boundary}--\r\n"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE  # PCO upload endpoint has CRL issues
    http.open_timeout = 30
    http.read_timeout = 120

    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    request.basic_auth(ENV['ROL_PLANNING_CENTER_CLIENT_ID'], ENV['ROL_PLANNING_CENTER_SECRET'])
    request.body = post_body

    response = http.request(request)

    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      file_uuid = data.dig("data", 0, "id") || data.dig("data", "id")
      if file_uuid
        puts "  ✓ Uploaded to PCO (UUID: #{file_uuid})"
        return file_uuid
      end
    end

    puts "  ✗ PCO file upload failed: #{response.code} - #{response.body[0..200]}"
    nil
  rescue => e
    puts "  ✗ PCO file upload error: #{e.message}"
    nil
  end

  def create_media_attachment(file_uuid, filename)
    api = PCO::Client.api

    # Create attachment using the file UUID
    attachment_data = {
      data: {
        type: "Attachment",
        attributes: {
          file_upload_identifier: file_uuid
        }
      }
    }

    response = api.services.v2.media[PCO_MEDIA_ID].attachments.post(attachment_data)

    if response.dig("data", "id")
      puts "  ✓ Created attachment in PCO Services Media"
      true
    else
      puts "  ✗ Failed to create attachment"
      false
    end
  rescue => e
    puts "  ✗ PCO attachment error: #{e.message}"
    false
  end

  def update_hero_images_json(new_images)
    puts "INFO: Updating hero_images.json..."

    # Load existing data
    existing = if File.exist?(DATA_FILE)
      JSON.parse(File.read(DATA_FILE))
    else
      { "slider" => [], "headers" => {} }
    end

    # Add new images to slider array (sorted by created_at, newest first)
    new_images.each do |img|
      slider_entry = {
        "id" => img[:post_id],
        "filename" => img[:filename],
        "path" => img[:path],
        "webp" => img[:webp_path],
        "source" => "facebook",
        "created_at" => img[:created_at]
      }

      # Insert at position based on created_at (maintain order by date)
      existing["slider"] ||= []
      existing["slider"] << slider_entry
    end

    # Sort slider by created_at descending (newest first)
    existing["slider"].sort_by! { |img| img["created_at"] || "1970-01-01" }.reverse!

    # Write back
    File.write(DATA_FILE, JSON.pretty_generate(existing))
    puts "INFO: Updated hero_images.json with #{new_images.length} new images"
    puts "INFO: Total slider images: #{existing["slider"].length}"
  end

  def cleanup
    # Remove temp directory
    FileUtils.rm_rf(TEMP_DIR) if Dir.exist?(TEMP_DIR)
  end
end

if __FILE__ == $0
  puts "Facebook Photo Sync for River of Life Church"
  puts "============================================="
  puts ""

  sync = FacebookPhotoSync.new
  success = sync.run

  exit(success ? 0 : 1)
end
