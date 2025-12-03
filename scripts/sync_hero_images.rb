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
require "parallel"

# Set timezone to Central Time
ENV['TZ'] = 'America/Chicago'
Time.zone = 'America/Chicago' if Time.respond_to?(:zone=)

# Force immediate output
$stdout.sync = true
$stderr.sync = true

HERO_DIR = File.join(__dir__, "..", "public", "hero")
MEDIA_ID = ENV["PCO_WEBSITE_HERO_MEDIA_ID"]

# Parallel threads for downloads
PARALLEL_THREADS = 4

# Helper method to download a single attachment
def download_attachment(api, attachment_id, filename)
  begin
    open_response = api.services.v2.attachments[attachment_id].open.post
    download_url = open_response.dig('data', 'attributes', 'attachment_url')

    unless download_url
      return { success: false, error: "No download URL returned" }
    end

    # Download the file from the authenticated URL
    uri = URI(download_url)
    redirect_limit = 5

    redirect_limit.times do |redirect_count|
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.open_timeout = 30
      http.read_timeout = 60

      request = Net::HTTP::Get.new(uri.request_uri)
      response = http.request(request)

      case response
      when Net::HTTPSuccess
        content_type = response['content-type'] || ''
        if content_type.include?('text/html')
          return { success: false, error: "Got HTML instead of image" }
        end

        # Save to temp file first
        temp_path = File.join(HERO_DIR, "#{filename}.tmp")
        File.binwrite(temp_path, response.body)

        # Optimize the image for web
        file_path = File.join(HERO_DIR, filename)
        ImageUtils.optimize_image(temp_path, file_path, ImageUtils::HERO_MAX_WIDTH, ImageUtils::HERO_MAX_HEIGHT)

        # Clean up temp file
        File.delete(temp_path) if File.exist?(temp_path)
        return { success: true }
      when Net::HTTPRedirection
        uri = URI(response['location'])
      else
        return { success: false, error: "HTTP #{response.code}" }
      end
    end

    { success: false, error: "Too many redirects" }
  rescue => e
    { success: false, error: e.message }
  end
end

def download_hero_images
  puts "INFO: Starting download_hero_images function"

  unless MEDIA_ID
    puts "ERROR: PCO_WEBSITE_HERO_MEDIA_ID environment variable not set"
    return false
  end

  # Create hero directory if it doesn't exist
  Dir.mkdir(HERO_DIR) unless Dir.exist?(HERO_DIR)

  # Clear existing PCO-sourced hero images (numbered and header_* files)
  # Preserve fb_* files (Facebook-sourced photos synced via sync_facebook_photos.rb)
  Dir.glob(File.join(HERO_DIR, '*.{jpg,png,webp}')).each do |f|
    basename = File.basename(f)
    File.delete(f) unless basename.start_with?('fb_')
  end

  puts "INFO: Fetching hero images from Planning Center Media ID: #{MEDIA_ID}"

  begin
    api = PCO::Client.api
    errors = []

    # Fetch media attachments
    attachments_response = api.services.v2.media[MEDIA_ID].attachments.get(per_page: 100)
    attachments = attachments_response['data'] || []

    puts "INFO: Found #{attachments.length} total images"

    if attachments.empty?
      puts "INFO: No PCO attachments, checking for Facebook-sourced images..."
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

    # Prepare download jobs for parallel processing
    download_jobs = []

    # Header images (keep original filename like header_pastor.jpg)
    header_attachments.each do |attachment|
      attachment_id = attachment['id']
      original_filename = attachment.dig('attributes', 'filename')
      extension = File.extname(original_filename).downcase
      extension = '.jpg' if extension.empty?
      basename = File.basename(original_filename, '.*').downcase
      filename = "#{basename}#{extension}"
      download_jobs << { id: attachment_id, filename: filename, type: :header }
    end

    # Slider images (numbered 1.jpg, 2.jpg, etc.)
    slider_attachments.each_with_index do |attachment, index|
      attachment_id = attachment['id']
      original_filename = attachment.dig('attributes', 'filename') || "hero-#{index}.jpg"
      extension = File.extname(original_filename).downcase
      extension = '.jpg' if extension.empty?
      filename = "#{index + 1}#{extension}"
      download_jobs << { id: attachment_id, filename: filename, type: :slider }
    end

    # Download all images in parallel
    puts "INFO: Downloading #{download_jobs.length} images in parallel..."
    results = { header: [], slider: [] }
    mutex = Mutex.new

    Parallel.each(download_jobs, in_threads: PARALLEL_THREADS) do |job|
      result = download_attachment(api, job[:id], job[:filename])
      mutex.synchronize do
        if result[:success]
          results[job[:type]] << job[:filename]
        else
          errors << "#{job[:filename]}: #{result[:error]}"
        end
      end
    end

    puts "SUCCESS: Downloaded #{results[:header].length} header and #{results[:slider].length} slider images"

    # Report errors
    if errors.any?
      puts "WARN: #{errors.length} download errors:"
      errors.first(5).each { |e| puts "  - #{e}" }
    end

    # Validate downloaded PCO images and remove small files
    all_files = Dir.glob(File.join(HERO_DIR, '*.{jpg,png}')).sort
    valid_slider_files = []
    valid_header_files = []

    all_files.each do |file|
      file_size = File.size(file)
      basename = File.basename(file)

      # Skip Facebook-sourced files
      if basename.start_with?('fb_')
        next
      end

      # Skip files that are too small (likely HTML error pages)
      if file_size < 20000
        puts "WARN: Removing #{basename} - file too small (#{file_size} bytes)"
        File.delete(file)
        next
      end

      if basename.start_with?('header_')
        valid_header_files << basename
      else
        valid_slider_files << basename
      end
    end

    puts "INFO: Validated #{valid_slider_files.length} PCO slider images and #{valid_header_files.length} header images"

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

    # Header files mapping for PageHero component
    header_mapping = {}
    valid_header_files.each do |f|
      page_key = f.sub(/^header_/, '').sub(/\.(jpg|png)$/, '')
      header_mapping[page_key] = "/hero/#{f}"
    end

    # Include Facebook-sourced photos (fb_*.jpg files)
    fb_files.sort! { |a, b| b <=> a }  # Descending sort (newest first)
    fb_slider_paths = fb_files.map { |f| "/hero/#{f}" }

    # PCO-sourced slider images (numbered 1.jpg, 2.jpg, etc.)
    pco_slider_paths = valid_slider_files.sort_by { |f| f.scan(/\d+/).first.to_i }.map { |f| "/hero/#{f}" }

    # Combine: Facebook photos first (newest), then PCO photos
    all_slider_paths = fb_slider_paths + pco_slider_paths

    File.write(hero_json_path, JSON.pretty_generate({
      updated_at: Time.now.iso8601,
      images: all_slider_paths,
      headers: header_mapping
    }))

    puts "INFO: Generated hero_images.json with #{all_slider_paths.length} slider images (#{fb_slider_paths.length} FB, #{pco_slider_paths.length} PCO)"

    return true
  rescue => e
    puts "ERROR downloading hero images: #{e.message}"
    puts "ERROR class: #{e.class}"
    puts e.backtrace.first(5).join("\n")
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
