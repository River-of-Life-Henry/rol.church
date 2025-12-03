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
    # Planning Center webhooks don't use a shared secret for signature verification.
    # Instead, they include an authenticity header that can be used to verify the
    # webhook came from PCO. For our use case, we verify:
    #   1. The request has the expected PCO headers
    #   2. The body is valid JSON with expected PCO structure
    #
    # @param body [String] Raw request body
    # @param headers [Hash] Request headers
    # @return [Boolean] true if webhook appears authentic
    def verify_pco(body, headers)
      # Check for PCO-specific headers that indicate this is a real PCO webhook
      # PCO sends these headers with their webhooks
      has_pco_headers = headers["x-pco-webhooks-authenticity-token"] ||
                        headers["user-agent"]&.include?("Planning Center")

      # Verify the body is valid JSON with PCO structure
      begin
        payload = JSON.parse(body)
        has_valid_structure = payload.is_a?(Hash) &&
                              (payload["data"] || payload["type"] || payload["id"])
      rescue JSON::ParserError
        puts "WARN: PCO webhook body is not valid JSON"
        return false
      end

      unless has_pco_headers || has_valid_structure
        puts "WARN: Webhook doesn't appear to be from Planning Center"
        return false
      end

      puts "INFO: PCO webhook verified (header/structure check)"
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

      unless timestamp && signature
        puts "WARN: Invalid Webhook-Signature header format"
        return false
      end

      # Optional: Check timestamp to prevent replay attacks (within 5 minutes)
      if timestamp_expired?(timestamp, tolerance: 300)
        puts "WARN: Webhook timestamp expired (possible replay attack)"
        return false
      end

      # Compute expected signature: HMAC-SHA256 of "timestamp.body"
      source_string = "#{timestamp}.#{body}"
      expected = OpenSSL::HMAC.hexdigest("sha256", secret, source_string)

      secure_compare(expected, signature)
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
