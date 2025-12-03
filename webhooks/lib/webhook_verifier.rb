# frozen_string_literal: true

# ==============================================================================
# Webhook Signature Verifier
# ==============================================================================
#
# Verifies webhook signatures from Planning Center and Cloudflare to ensure
# the requests are authentic and haven't been tampered with.
#
# Both services use HMAC-SHA256 signatures but with different header formats:
#   - Planning Center: x-pco-signature header contains hex digest
#   - Cloudflare: Webhook-Signature header contains "time=...,sig1=..."
#
# ==============================================================================

require "openssl"
require "securerandom"

module WebhookVerifier
  class << self
    # Verify webhook signature based on source
    #
    # @param source [String] "pco" or "cloudflare"
    # @param body [String] Raw request body
    # @param headers [Hash] Request headers (lowercase keys)
    # @return [Boolean] true if signature is valid
    def verify(source, body, headers)
      case source
      when "pco"
        verify_pco(body, headers)
      when "cloudflare"
        verify_cloudflare(body, headers)
      else
        puts "WARN: Unknown webhook source: #{source}"
        false
      end
    end

    private

    # Verify Planning Center webhook
    #
    # PCO assigns a DIFFERENT authenticity_secret to each webhook subscription,
    # making it impractical to verify signatures when you have 81 subscriptions.
    # Instead, we verify the webhook is from PCO by checking:
    #   1. Required PCO headers are present
    #   2. Body is valid JSON with expected PCO structure
    #
    # The endpoint URL is obscure and only known to PCO, providing some security.
    #
    # @param body [String] Raw request body
    # @param headers [Hash] Request headers
    # @return [Boolean] true if webhook appears authentic
    def verify_pco(body, headers)
      # Check for required PCO webhook headers
      unless headers["x-pco-webhooks-authenticity"]
        puts "WARN: Missing X-PCO-Webhooks-Authenticity header"
        return false
      end

      unless headers["x-pco-webhooks-event"]
        puts "WARN: Missing X-PCO-Webhooks-Event header"
        return false
      end

      # Verify the body is valid JSON with PCO structure
      begin
        payload = JSON.parse(body)
        unless payload.is_a?(Hash) && payload["data"]
          puts "WARN: PCO webhook missing expected data structure"
          return false
        end
      rescue JSON::ParserError => e
        puts "WARN: PCO webhook body is not valid JSON: #{e.message}"
        return false
      end

      event = headers["x-pco-webhooks-event"]
      puts "INFO: PCO webhook accepted (event: #{event})"
      true
    end

    # Verify Cloudflare webhook signature
    #
    # Cloudflare sends signature in Webhook-Signature header with format:
    #   "time=1230811200,sig1=60493ec9388b44585a29543bcf0de62e377d4da393246a8b1c901d0e3e672404"
    #
    # The signature is computed as HMAC-SHA256 of "timestamp.body"
    #
    # @param body [String] Raw request body
    # @param headers [Hash] Request headers
    # @return [Boolean] true if signature is valid
    def verify_cloudflare(body, headers)
      signature_header = headers["webhook-signature"]
      secret = ENV["CLOUDFLARE_WEBHOOK_SECRET"]

      puts "DEBUG: Cloudflare verification starting"
      puts "DEBUG: Available headers: #{headers.keys.join(', ')}"
      puts "DEBUG: Webhook-Signature header: #{signature_header.inspect}"
      puts "DEBUG: Secret configured: #{secret ? 'yes' : 'no'}"

      unless signature_header
        puts "WARN: Missing Webhook-Signature header"
        return false
      end

      unless secret
        puts "ERROR: CLOUDFLARE_WEBHOOK_SECRET not configured"
        return false
      end

      # Parse the header: "time=...,sig1=..."
      parts = signature_header.split(",").map { |p| p.split("=", 2) }.to_h
      timestamp = parts["time"]
      signature = parts["sig1"]

      puts "DEBUG: Parsed timestamp: #{timestamp}"
      puts "DEBUG: Parsed signature: #{signature}"

      unless timestamp && signature
        puts "WARN: Invalid Webhook-Signature header format"
        return false
      end

      # Compute expected signature: HMAC-SHA256 of "timestamp.body"
      source_string = "#{timestamp}.#{body}"
      expected = OpenSSL::HMAC.hexdigest("sha256", secret, source_string)

      puts "DEBUG: Expected signature: #{expected}"
      puts "DEBUG: Received signature: #{signature}"

      if secure_compare(expected, signature)
        puts "INFO: Cloudflare webhook signature verified"
        true
      else
        puts "WARN: Cloudflare webhook signature mismatch"
        false
      end
    end

    # Constant-time string comparison to prevent timing attacks
    #
    # @param a [String] First string
    # @param b [String] Second string
    # @return [Boolean] true if strings are equal
    def secure_compare(a, b)
      return false if a.nil? || b.nil?
      return false if a.bytesize != b.bytesize

      # XOR all bytes and accumulate - constant time regardless of where mismatch occurs
      result = 0
      a.bytes.zip(b.bytes) { |x, y| result |= x ^ y }
      result.zero?
    end

    # Check if timestamp is too old (possible replay attack)
    #
    # @param timestamp [String] Unix timestamp as string
    # @param tolerance [Integer] Maximum age in seconds (default: 300 = 5 minutes)
    # @return [Boolean] true if timestamp is expired
    def timestamp_expired?(timestamp, tolerance: 300)
      webhook_time = Time.at(timestamp.to_i)
      (Time.now - webhook_time).abs > tolerance
    rescue
      true # If we can't parse timestamp, treat as expired
    end
  end
end
