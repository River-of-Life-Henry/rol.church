# frozen_string_literal: true

# Image optimization utilities for sync scripts
# Supports resizing and compression for web optimization
# Uses sips (macOS) or ImageMagick (Linux) automatically
# Generates WebP versions for modern browsers

require "net/http"
require "uri"
require "openssl"
require "fileutils"

module ImageUtils
  # Maximum dimensions for different image types
  HERO_MAX_WIDTH = 1920
  HERO_MAX_HEIGHT = 1080
  LEADER_MAX_SIZE = 400  # Square for small avatars
  TEAM_MAX_SIZE = 1200   # Larger for featured team photos (pastor page)
  HEADER_MAX_WIDTH = 1200
  HEADER_MAX_HEIGHT = 600

  # JPEG quality for compression (0-100)
  JPEG_QUALITY = 80
  WEBP_QUALITY = 65  # More aggressive for smaller files

  class << self
    # Download and optimize an image for web
    # @param url [String] Source URL
    # @param output_path [String] Full path to save the optimized image
    # @param type [Symbol] :hero, :leader, :header, or :team
    # @return [Boolean] true if successful
    def download_and_optimize(url, output_path, type: :hero)
      # Download to temp file first
      temp_path = "#{output_path}.tmp"

      return false unless download_file(url, temp_path)

      # Get dimensions based on type
      max_width, max_height = dimensions_for_type(type)

      # Optimize the image
      success = optimize_image(temp_path, output_path, max_width, max_height)

      # Clean up temp file
      File.delete(temp_path) if File.exist?(temp_path)

      success
    end

    # Download a file from URL with redirect following
    # @param url [String] Source URL
    # @param output_path [String] Path to save the file
    # @return [Boolean] true if successful
    def download_file(url, output_path)
      uri = URI(url)
      redirect_limit = 5

      redirect_limit.times do
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
            puts "WARNING: Got HTML instead of image"
            return false
          end

          File.binwrite(output_path, response.body)
          return true

        when Net::HTTPRedirection
          uri = URI(response['location'])

        else
          puts "WARNING: Failed to download: HTTP #{response.code}"
          return false
        end
      end

      puts "WARNING: Too many redirects"
      false
    end

    # Optimize an image (resize and compress)
    # @param input_path [String] Source file path
    # @param output_path [String] Destination file path
    # @param max_width [Integer] Maximum width
    # @param max_height [Integer] Maximum height
    # @return [Boolean] true if successful
    def optimize_image(input_path, output_path, max_width, max_height)
      unless File.exist?(input_path)
        puts "ERROR: Input file does not exist: #{input_path}"
        return false
      end

      original_size = File.size(input_path)

      # Try sips (macOS) first, then ImageMagick
      if macos?
        success = optimize_with_sips(input_path, output_path, max_width, max_height)
      elsif imagemagick_available?
        success = optimize_with_imagemagick(input_path, output_path, max_width, max_height)
      else
        # No optimization available - just copy the file
        puts "INFO: No image optimization tool available, using original"
        FileUtils.cp(input_path, output_path)
        return true
      end

      if success && File.exist?(output_path)
        new_size = File.size(output_path)
        reduction = ((original_size - new_size).to_f / original_size * 100).round(1)

        if new_size < original_size
          puts "INFO: Optimized image: #{format_bytes(original_size)} -> #{format_bytes(new_size)} (#{reduction}% smaller)"
        else
          # If optimization made it larger, keep original
          puts "INFO: Optimization increased size, keeping original (#{format_bytes(original_size)})"
          FileUtils.cp(input_path, output_path)
        end

        # Generate WebP version
        generate_webp(output_path)

        true
      else
        false
      end
    end

    # Generate WebP version of an image
    # @param input_path [String] Source JPEG/PNG file
    # @return [Boolean] true if successful
    def generate_webp(input_path)
      webp_path = input_path.sub(/\.(jpg|jpeg|png)$/i, '.webp')

      if cwebp_available?
        result = system("cwebp -q #{WEBP_QUALITY} \"#{input_path}\" -o \"#{webp_path}\" 2>/dev/null")
        if result && File.exist?(webp_path)
          webp_size = File.size(webp_path)
          orig_size = File.size(input_path)
          puts "INFO: Generated WebP: #{format_bytes(webp_size)} (#{((orig_size - webp_size).to_f / orig_size * 100).round(1)}% smaller than JPEG)"
          return true
        end
      elsif imagemagick_available?
        result = system("convert \"#{input_path}\" -quality #{WEBP_QUALITY} \"#{webp_path}\" 2>/dev/null")
        if result && File.exist?(webp_path)
          webp_size = File.size(webp_path)
          orig_size = File.size(input_path)
          puts "INFO: Generated WebP: #{format_bytes(webp_size)} (#{((orig_size - webp_size).to_f / orig_size * 100).round(1)}% smaller than JPEG)"
          return true
        end
      else
        puts "INFO: No WebP converter available, skipping WebP generation"
      end

      false
    end

    private

    def dimensions_for_type(type)
      case type
      when :hero
        [HERO_MAX_WIDTH, HERO_MAX_HEIGHT]
      when :leader
        [LEADER_MAX_SIZE, LEADER_MAX_SIZE]
      when :team
        [TEAM_MAX_SIZE, TEAM_MAX_SIZE]
      when :header
        [HEADER_MAX_WIDTH, HEADER_MAX_HEIGHT]
      else
        [HERO_MAX_WIDTH, HERO_MAX_HEIGHT]
      end
    end

    def macos?
      RUBY_PLATFORM.include?('darwin')
    end

    def imagemagick_available?
      system('which convert > /dev/null 2>&1')
    end

    def cwebp_available?
      system('which cwebp > /dev/null 2>&1')
    end

    def optimize_with_sips(input_path, output_path, max_width, max_height)
      # sips can resize and change format
      # First, get current dimensions
      dimensions = `sips -g pixelWidth -g pixelHeight "#{input_path}" 2>/dev/null`

      width = dimensions[/pixelWidth:\s*(\d+)/, 1].to_i
      height = dimensions[/pixelHeight:\s*(\d+)/, 1].to_i

      if width == 0 || height == 0
        puts "WARNING: Could not read image dimensions"
        FileUtils.cp(input_path, output_path)
        return true
      end

      # Calculate new dimensions maintaining aspect ratio
      if width > max_width || height > max_height
        width_ratio = max_width.to_f / width
        height_ratio = max_height.to_f / height
        ratio = [width_ratio, height_ratio].min

        new_width = (width * ratio).to_i
        new_height = (height * ratio).to_i

        puts "INFO: Resizing #{width}x#{height} -> #{new_width}x#{new_height}"

        # Copy to output first, then resize in place (sips modifies in place)
        FileUtils.cp(input_path, output_path)

        # Resize with sips
        result = system("sips --resampleHeightWidth #{new_height} #{new_width} \"#{output_path}\" > /dev/null 2>&1")

        unless result
          puts "WARNING: sips resize failed"
          return false
        end
      else
        FileUtils.cp(input_path, output_path)
        puts "INFO: Image already within bounds (#{width}x#{height})"
      end

      # Convert to JPEG with compression if not already JPEG
      ext = File.extname(output_path).downcase
      if ext != '.jpg' && ext != '.jpeg'
        jpg_path = output_path.sub(/\.[^.]+$/, '.jpg')
        result = system("sips -s format jpeg -s formatOptions #{JPEG_QUALITY} \"#{output_path}\" --out \"#{jpg_path}\" > /dev/null 2>&1")
        if result && File.exist?(jpg_path)
          File.delete(output_path) if output_path != jpg_path
          FileUtils.mv(jpg_path, output_path) if jpg_path != output_path
        end
      else
        # Re-compress existing JPEG
        # sips doesn't have great compression options, so we do a format conversion to itself
        temp_path = "#{output_path}.recompress"
        result = system("sips -s format jpeg -s formatOptions #{JPEG_QUALITY} \"#{output_path}\" --out \"#{temp_path}\" > /dev/null 2>&1")
        if result && File.exist?(temp_path)
          FileUtils.mv(temp_path, output_path)
        end
      end

      true
    end

    def optimize_with_imagemagick(input_path, output_path, max_width, max_height)
      # ImageMagick convert with resize and compression
      # -resize WxH> means only shrink if larger, maintain aspect ratio
      # -quality sets JPEG compression
      # -strip removes metadata

      # Detect image format from file header (magic bytes)
      # This is needed because temp files may not have proper extensions
      format_hint = detect_image_format(input_path)

      # Log format detection result for debugging
      if format_hint
        puts "INFO: Detected format #{format_hint} for #{File.basename(input_path)}"
      else
        # Read bytes for debugging
        magic = File.binread(input_path, 8) rescue nil
        if magic
          hex = magic.bytes.map { |b| '%02x' % b }.join(' ')
          puts "WARN: Could not detect format for #{File.basename(input_path)}, magic: #{hex}"
        else
          puts "WARN: Could not read #{File.basename(input_path)}"
        end
      end

      input_spec = format_hint ? "#{format_hint}:#{input_path}" : input_path

      cmd = [
        "convert",
        "\"#{input_spec}\"",
        "-resize", "#{max_width}x#{max_height}>",
        "-quality", JPEG_QUALITY.to_s,
        "-strip",
        "-interlace", "Plane",  # Progressive JPEG
        "\"#{output_path}\""
      ].join(" ")

      result = system(cmd)

      unless result
        puts "WARNING: ImageMagick convert failed for #{File.basename(input_path)}"
        return false
      end

      true
    end

    # Detect image format from file magic bytes
    def detect_image_format(path)
      return nil unless File.exist?(path)

      magic = File.binread(path, 16)
      return nil if magic.nil? || magic.length < 4

      # Get bytes as integers for reliable comparison
      bytes = magic.bytes

      # JPEG: starts with ff d8 ff
      if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
        return "jpeg"
      end

      # PNG: starts with 89 50 4e 47 0d 0a 1a 0a (89 P N G \r \n \x1a \n)
      if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47
        return "png"
      end

      # GIF: starts with GIF87a or GIF89a
      if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 # "GIF"
        return "gif"
      end

      # WebP: RIFF....WEBP
      if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 && # RIFF
         bytes.length >= 12 && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 # WEBP
        return "webp"
      end

      nil
    end

    def format_bytes(bytes)
      if bytes >= 1_048_576
        "#{(bytes / 1_048_576.0).round(1)}MB"
      elsif bytes >= 1024
        "#{(bytes / 1024.0).round(1)}KB"
      else
        "#{bytes}B"
      end
    end
  end
end
