# frozen_string_literal: true

# ==============================================================================
# Webhook Subscription Manager
# ==============================================================================
#
# Manages webhook subscriptions with Planning Center and Cloudflare.
# Used by setup/teardown scripts to register and remove webhook endpoints.
#
# Planning Center Webhooks:
#   - Supports multiple webhook subscriptions per application
#   - Events: person.created, person.updated, person.destroyed, etc.
#   - API: https://api.planningcenteronline.com/webhooks/v2/subscriptions
#
# Cloudflare Stream Webhooks:
#   - Only one webhook URL per account
#   - Events: Video processing complete, live stream events
#   - API: https://api.cloudflare.com/client/v4/accounts/{account_id}/stream/webhook
#
# ==============================================================================

require "net/http"
require "uri"
require "json"
require "base64"

module WebhookManager
  # Planning Center API configuration
  PCO_API_BASE = "https://api.planningcenteronline.com"

  # Cloudflare API configuration
  CF_API_BASE = "https://api.cloudflare.com/client/v4"

  class << self
    # =========================================================================
    # Planning Center Webhook Management
    # =========================================================================

    # List all PCO webhook subscriptions
    def list_pco_webhooks
      response = pco_request(:get, "/webhooks/v2/subscriptions")
      response["data"] || []
    end

    # Create a PCO webhook subscription
    #
    # @param name [String] Friendly name for the webhook
    # @param url [String] URL to receive webhooks
    # @return [Hash] Created subscription data including authenticity_secret
    def create_pco_webhook(name:, url:)
      payload = {
        data: {
          type: "Subscription",
          attributes: {
            name: name,
            url: url,
            active: true
          }
        }
      }

      response = pco_request(:post, "/webhooks/v2/subscriptions", payload)
      response["data"]
    end

    # Delete a PCO webhook subscription
    #
    # @param subscription_id [String] ID of the subscription to delete
    def delete_pco_webhook(subscription_id)
      pco_request(:delete, "/webhooks/v2/subscriptions/#{subscription_id}")
    end

    # Delete all PCO webhooks matching a URL pattern
    #
    # @param url_pattern [String] URL pattern to match (e.g., "webhooks.api.rol.church")
    def delete_pco_webhooks_matching(url_pattern)
      webhooks = list_pco_webhooks
      matching = webhooks.select { |w| w.dig("attributes", "url")&.include?(url_pattern) }

      matching.each do |webhook|
        puts "Deleting PCO webhook: #{webhook['id']} - #{webhook.dig('attributes', 'name')}"
        delete_pco_webhook(webhook["id"])
      end

      matching.length
    end

    # =========================================================================
    # Cloudflare Webhook Management
    # =========================================================================

    # Get current Cloudflare Stream webhook configuration
    def get_cloudflare_webhook
      response = cloudflare_request(:get, "/accounts/#{cloudflare_account_id}/stream/webhook")
      response["result"]
    end

    # Create or update Cloudflare Stream webhook
    #
    # @param url [String] URL to receive webhooks
    # @return [Hash] Webhook configuration including the signing secret
    def set_cloudflare_webhook(url)
      payload = { notificationUrl: url }
      response = cloudflare_request(:put, "/accounts/#{cloudflare_account_id}/stream/webhook", payload)
      response["result"]
    end

    # Delete Cloudflare Stream webhook
    def delete_cloudflare_webhook
      cloudflare_request(:delete, "/accounts/#{cloudflare_account_id}/stream/webhook")
    end

    private

    # =========================================================================
    # API Request Helpers
    # =========================================================================

    # Make authenticated request to Planning Center API
    def pco_request(method, path, body = nil)
      uri = URI("#{PCO_API_BASE}#{path}")

      request = case method
                when :get then Net::HTTP::Get.new(uri)
                when :post then Net::HTTP::Post.new(uri)
                when :put then Net::HTTP::Put.new(uri)
                when :delete then Net::HTTP::Delete.new(uri)
                end

      # Basic auth with PCO credentials
      request.basic_auth(
        ENV["ROL_PLANNING_CENTER_CLIENT_ID"],
        ENV["ROL_PLANNING_CENTER_SECRET"]
      )

      request["Accept"] = "application/json"
      request["Content-Type"] = "application/json"

      if body
        request.body = JSON.generate(body)
      end

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(request)
      end

      case response
      when Net::HTTPSuccess, Net::HTTPNoContent
        response.body.to_s.empty? ? {} : JSON.parse(response.body)
      else
        raise "PCO API error: #{response.code} - #{response.body}"
      end
    end

    # Make authenticated request to Cloudflare API
    def cloudflare_request(method, path, body = nil)
      uri = URI("#{CF_API_BASE}#{path}")

      request = case method
                when :get then Net::HTTP::Get.new(uri)
                when :post then Net::HTTP::Post.new(uri)
                when :put then Net::HTTP::Put.new(uri)
                when :delete then Net::HTTP::Delete.new(uri)
                end

      request["Authorization"] = "Bearer #{ENV['CLOUDFLARE_API_TOKEN']}"
      request["Content-Type"] = "application/json"

      if body
        request.body = JSON.generate(body)
      end

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(request)
      end

      result = JSON.parse(response.body)

      unless result["success"]
        errors = result["errors"]&.map { |e| e["message"] }&.join(", ") || "Unknown error"
        raise "Cloudflare API error: #{errors}"
      end

      result
    end

    def cloudflare_account_id
      ENV["CLOUDFLARE_ACCOUNT_ID"] || raise("CLOUDFLARE_ACCOUNT_ID not set")
    end
  end
end
