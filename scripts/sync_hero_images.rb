#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync hero images from Planning Center Media to the website
# Usage: ruby sync_hero_images.rb

require_relative "pco_client"
require "json"
require "net/http"
require "uri"
require "openssl"
require "time"

# Force immediate output
$stdout.sync = true
$stderr.sync = true

HERO_DIR = File.join(__dir__, "..", "public", "hero")
MEDIA_ID = ENV["PCO_WEBSITE_HERO_MEDIA_ID"]

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

  # Clear existing hero images
  Dir.glob(File.join(HERO_DIR, '*.jpg')).each { |f| File.delete(f) }
  Dir.glob(File.join(HERO_DIR, '*.png')).each { |f| File.delete(f) }

  puts "INFO: Fetching hero images from Planning Center Media ID: #{MEDIA_ID}"
  puts "DEBUG: PCO client configured with client_id present: #{!ENV['ROL_PLANNING_CENTER_CLIENT_ID'].to_s.empty?}"
  puts "DEBUG: PCO client configured with secret present: #{!ENV['ROL_PLANNING_CENTER_SECRET'].to_s.empty?}"

  begin
    api = PCO::Client.api

    # Fetch media attachments
    puts "DEBUG: Making API request to services.v2.media[#{MEDIA_ID}].attachments.get"
    attachments_response = api.services.v2.media[MEDIA_ID].attachments.get(per_page: 100)

    puts "DEBUG: Raw API response keys: #{attachments_response.keys}"
    puts "DEBUG: Full API response: #{attachments_response.inspect}"

    attachments = attachments_response['data'] || []

    puts "INFO: Found #{attachments.length} hero images"

    if attachments.empty?
      puts "WARNING: No attachments returned from API. Check if media ID #{MEDIA_ID} exists and has attachments."
      puts "DEBUG: Response errors: #{attachments_response['errors'].inspect}" if attachments_response['errors']
    end

    # Download each attachment
    attachments.each_with_index do |attachment, index|
      attachment_id = attachment['id']
      original_filename = attachment.dig('attributes', 'filename') || "hero-#{index}.jpg"

      # Rename to numbered format (1.jpg, 2.jpg, etc.)
      extension = File.extname(original_filename).downcase
      extension = '.jpg' if extension.empty?
      filename = "#{index + 1}#{extension}"

      puts "DEBUG: Processing attachment #{index + 1}/#{attachments.length}: ID=#{attachment_id}, filename=#{filename}"
      puts "DEBUG: Attachment attributes: #{attachment['attributes'].inspect}"

      begin
        # Request the attachment with open action to get a direct download URL
        puts "DEBUG: Fetching authenticated download URL for attachment #{attachment_id}"
        open_response = api.services.v2.attachments[attachment_id].open.post

        puts "DEBUG: Open response: #{open_response.inspect}"

        # The response should contain an attachment_url for direct download
        download_url = open_response.dig('data', 'attributes', 'attachment_url')

        unless download_url
          puts "WARNING: No download URL returned for attachment #{attachment_id}"
          puts "DEBUG: Response data: #{open_response['data']&.dig('attributes')&.keys}"
          next
        end

        puts "DEBUG: Got authenticated download URL: #{download_url[0..80]}..."

        # Download the file from the authenticated URL
        uri = URI(download_url)
        redirect_limit = 5
        redirect_count = 0

        redirect_limit.times do
          redirect_count += 1
          puts "DEBUG: HTTP request #{redirect_count} to #{uri.host}..."

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
              puts "DEBUG: Response body preview: #{response.body[0..200]}"
              break
            end

            # Save to hero directory
            file_path = File.join(HERO_DIR, filename)
            File.binwrite(file_path, response.body)
            puts "INFO: Downloaded hero image: #{filename} (#{response.body.bytesize} bytes, #{content_type})"
            break
          when Net::HTTPRedirection
            # Follow redirect
            new_location = response['location']
            puts "DEBUG: Redirecting to: #{new_location[0..80]}..."
            uri = URI(new_location)
          else
            puts "ERROR: Failed to download #{filename}: HTTP #{response.code} #{response.message}"
            puts "DEBUG: Response body: #{response.body[0..500]}" if response.body
            break
          end
        end
      rescue => download_error
        puts "ERROR: Failed to download attachment #{attachment_id}: #{download_error.message}"
        puts download_error.backtrace.first(3).join("\n")
      end
    end

    puts "SUCCESS: Finished downloading hero images"

    # Validate downloaded images
    hero_files = []
    Dir.glob(File.join(HERO_DIR, '*.{jpg,png}')).sort.each do |file|
      file_size = File.size(file)

      # Skip files that are too small (likely HTML error pages)
      if file_size < 20000
        puts "WARNING: Skipping #{File.basename(file)} - file too small (#{file_size} bytes), likely not a valid image"
        File.delete(file)
        next
      end

      hero_files << File.basename(file)
      puts "DEBUG: Verified valid hero image: #{File.basename(file)} (#{file_size} bytes)"
    end

    puts "INFO: Downloaded #{hero_files.length} valid hero images"

    if hero_files.empty?
      puts "ERROR: No valid hero images were downloaded!"
      return false
    end

    # Generate hero_images.json for the HeroSlider component
    hero_json_path = File.join(__dir__, "..", "src", "data", "hero_images.json")
    hero_paths = hero_files.sort_by { |f| f.scan(/\d+/).first.to_i }.map { |f| "/hero/#{f}" }
    File.write(hero_json_path, JSON.pretty_generate({
      updated_at: Time.now.iso8601,
      images: hero_paths
    }))
    puts "INFO: Generated hero_images.json with #{hero_paths.length} images"

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
