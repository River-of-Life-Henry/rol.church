#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync hero images from Planning Center Media to the website
# Usage: ruby sync_hero_images.rb
#
# Image naming convention:
# - header_<pagename>.jpg/png: Page-specific hero backgrounds
#   The pagename is the URL path with non-alphanumeric chars replaced by underscores
#   Examples:
#     header_pastor.jpg -> /pastor/
#     header_next_steps_visit.jpg -> /next-steps/visit/
#     header_groups_hyphen.jpg -> /groups/hyphen/
#
# - All other images (1.jpg, 2.jpg, etc.): Used in home page hero slider
#   These are numbered sequentially, excluding any header_* files

require_relative "pco_client"
require_relative "image_utils"
require "json"
require "net/http"
require "uri"
require "openssl"
require "time"

# Set timezone to Central Time
ENV['TZ'] = 'America/Chicago'
Time.zone = 'America/Chicago' if Time.respond_to?(:zone=)

# Force immediate output
$stdout.sync = true
$stderr.sync = true

HERO_DIR = File.join(__dir__, "..", "public", "hero")
MEDIA_ID = ENV["PCO_WEBSITE_HERO_MEDIA_ID"]

# Helper method to download a single attachment
def download_attachment(api, attachment_id, filename)
  puts "DEBUG: Fetching authenticated download URL for attachment #{attachment_id}"
  open_response = api.services.v2.attachments[attachment_id].open.post

  download_url = open_response.dig('data', 'attributes', 'attachment_url')

  unless download_url
    puts "WARNING: No download URL returned for attachment #{attachment_id}"
    return false
  end

  puts "DEBUG: Got authenticated download URL: #{download_url[0..80]}..."

  # Download the file from the authenticated URL
  uri = URI(download_url)
  redirect_limit = 5

  redirect_limit.times do |redirect_count|
    puts "DEBUG: HTTP request #{redirect_count + 1} to #{uri.host}..."

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.open_timeout = 30
    http.read_timeout = 60

    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)

    puts "DEBUG: Response status: #{response.code} #{response.message}"

    case response
    when Net::HTTPSuccess
      # Verify it's actually an image (not HTML)
      content_type = response['content-type'] || ''
      if content_type.include?('text/html')
        puts "ERROR: Got HTML instead of image for #{filename}"
        return false
      end

      # Save to temp file first
      temp_path = File.join(HERO_DIR, "#{filename}.tmp")
      File.binwrite(temp_path, response.body)
      original_size = response.body.bytesize
      puts "INFO: Downloaded hero image: #{filename} (#{original_size} bytes, #{content_type})"

      # Optimize the image for web
      file_path = File.join(HERO_DIR, filename)
      ImageUtils.optimize_image(temp_path, file_path, ImageUtils::HERO_MAX_WIDTH, ImageUtils::HERO_MAX_HEIGHT)

      # Clean up temp file
      File.delete(temp_path) if File.exist?(temp_path)
      return true
    when Net::HTTPRedirection
      # Follow redirect
      new_location = response['location']
      puts "DEBUG: Redirecting to: #{new_location[0..80]}..."
      uri = URI(new_location)
    else
      puts "ERROR: Failed to download #{filename}: HTTP #{response.code} #{response.message}"
      return false
    end
  end

  false
end

def download_hero_images
  puts "INFO: Starting download_hero_images function"
  puts "INFO: Media ID: #{MEDIA_ID}"
  puts "INFO: Hero directory: #{HERO_DIR}"

  unless MEDIA_ID
    puts "ERROR: PCO_WEBSITE_HERO_MEDIA_ID environment variable not set"
    return false
  end

  # Create hero directory if it doesn't exist
  Dir.mkdir(HERO_DIR) unless Dir.exist?(HERO_DIR)

  # Clear existing PCO-sourced hero images (numbered and header_* files)
  # Preserve fb_* files (Facebook-sourced photos synced via sync_facebook_photos.rb)
  Dir.glob(File.join(HERO_DIR, '*.jpg')).each do |f|
    basename = File.basename(f)
    File.delete(f) unless basename.start_with?('fb_')
  end
  Dir.glob(File.join(HERO_DIR, '*.png')).each do |f|
    basename = File.basename(f)
    File.delete(f) unless basename.start_with?('fb_')
  end
  Dir.glob(File.join(HERO_DIR, '*.webp')).each do |f|
    basename = File.basename(f)
    File.delete(f) unless basename.start_with?('fb_')
  end

  puts "INFO: Fetching hero images from Planning Center Media ID: #{MEDIA_ID}"

  begin
    api = PCO::Client.api

    # Fetch media attachments
    attachments_response = api.services.v2.media[MEDIA_ID].attachments.get(per_page: 100)
    attachments = attachments_response['data'] || []

    puts "INFO: Found #{attachments.length} total images"

    if attachments.empty?
      puts "WARNING: No attachments returned from API. Checking for Facebook-sourced images..."
      # Don't return false - we might have Facebook images
    end

    # Separate header images from slider images
    header_attachments = []
    slider_attachments = []

    attachments.each do |attachment|
      original_filename = attachment.dig('attributes', 'filename') || ""
      if original_filename.downcase.start_with?('header_')
        header_attachments << attachment
      else
        slider_attachments << attachment
      end
    end

    puts "INFO: Found #{header_attachments.length} page header images and #{slider_attachments.length} slider images"

    # Download header images (keep original filename like header_pastor.jpg)
    header_files = []
    header_attachments.each_with_index do |attachment, index|
      attachment_id = attachment['id']
      original_filename = attachment.dig('attributes', 'filename')

      # Keep the header_* filename but normalize extension
      extension = File.extname(original_filename).downcase
      extension = '.jpg' if extension.empty?
      basename = File.basename(original_filename, '.*').downcase
      filename = "#{basename}#{extension}"

      puts "DEBUG: Processing header image #{index + 1}/#{header_attachments.length}: #{filename}"

      begin
        if download_attachment(api, attachment_id, filename)
          header_files << filename
        end
      rescue => e
        puts "ERROR: Failed to download header image #{filename}: #{e.message}"
      end
    end

    # Download slider images (numbered 1.jpg, 2.jpg, etc.)
    slider_files = []
    slider_attachments.each_with_index do |attachment, index|
      attachment_id = attachment['id']
      original_filename = attachment.dig('attributes', 'filename') || "hero-#{index}.jpg"

      # Rename to numbered format
      extension = File.extname(original_filename).downcase
      extension = '.jpg' if extension.empty?
      filename = "#{index + 1}#{extension}"

      puts "DEBUG: Processing slider image #{index + 1}/#{slider_attachments.length}: #{filename}"

      begin
        if download_attachment(api, attachment_id, filename)
          slider_files << filename
        end
      rescue => e
        puts "ERROR: Failed to download slider image #{filename}: #{e.message}"
      end
    end

    puts "SUCCESS: Finished downloading hero images"

    # Validate downloaded PCO images and remove small files
    # Note: fb_* files are from Facebook sync, not PCO, so we skip them here
    all_files = Dir.glob(File.join(HERO_DIR, '*.{jpg,png}')).sort
    valid_slider_files = []
    valid_header_files = []

    all_files.each do |file|
      file_size = File.size(file)
      basename = File.basename(file)

      # Skip Facebook-sourced files (they're handled separately)
      if basename.start_with?('fb_')
        puts "DEBUG: Verified valid image: #{basename} (#{file_size} bytes)"
        next
      end

      # Skip files that are too small (likely HTML error pages)
      if file_size < 20000
        puts "WARNING: Removing #{basename} - file too small (#{file_size} bytes)"
        File.delete(file)
        next
      end

      if basename.start_with?('header_')
        valid_header_files << basename
      else
        valid_slider_files << basename
      end

      puts "DEBUG: Verified valid PCO image: #{basename} (#{file_size} bytes)"
    end

    puts "INFO: Downloaded #{valid_slider_files.length} valid PCO slider images and #{valid_header_files.length} valid header images"

    # Check if we have Facebook-sourced images even if PCO is empty
    fb_files = Dir.glob(File.join(HERO_DIR, 'fb_*.jpg')).map { |f| File.basename(f) }

    if valid_slider_files.empty? && valid_header_files.empty? && fb_files.empty?
      puts "ERROR: No valid hero images were downloaded and no Facebook images exist!"
      return false
    elsif valid_slider_files.empty? && valid_header_files.empty?
      puts "INFO: No PCO images, but found #{fb_files.length} Facebook-sourced images"
    end

    # Generate hero_images.json for the HeroSlider component
    hero_json_path = File.join(__dir__, "..", "src", "data", "hero_images.json")

    # Also include header files mapping for PageHero component
    header_mapping = {}
    valid_header_files.each do |f|
      # Extract page key from filename: header_pastor.jpg -> pastor
      page_key = f.sub(/^header_/, '').sub(/\.(jpg|png)$/, '')
      header_mapping[page_key] = "/hero/#{f}"
    end

    # Include Facebook-sourced photos (fb_*.jpg files)
    # These are sorted by date (newest first based on filename: fb_YYYYMMDD_...)
    # fb_files already loaded above
    fb_files.sort! { |a, b| b <=> a }  # Descending sort (newest first)
    fb_slider_paths = fb_files.map { |f| "/hero/#{f}" }

    # PCO-sourced slider images (numbered 1.jpg, 2.jpg, etc.)
    pco_slider_paths = valid_slider_files.sort_by { |f| f.scan(/\d+/).first.to_i }.map { |f| "/hero/#{f}" }

    # Combine: Facebook photos first (newest), then PCO photos
    # User request: Home slider shows 5 most recent, page backgrounds use rest
    all_slider_paths = fb_slider_paths + pco_slider_paths

    File.write(hero_json_path, JSON.pretty_generate({
      updated_at: Time.now.iso8601,
      images: all_slider_paths,
      headers: header_mapping
    }))

    puts "INFO: Generated hero_images.json with #{all_slider_paths.length} slider images (#{fb_slider_paths.length} from Facebook, #{pco_slider_paths.length} from PCO) and #{header_mapping.length} page headers"

    return true
  rescue => e
    puts "ERROR downloading hero images: #{e.message}"
    puts "ERROR class: #{e.class}"
    puts e.backtrace.first(10).join("\n")
    return false
  end
end

if __FILE__ == $0
  puts "Syncing hero images from Planning Center..."
  success = download_hero_images
  if success
    puts "Done!"
    exit 0
  else
    puts "Failed to sync hero images"
    exit 1
  end
end
