# frozen_string_literal: true

# ==============================================================================
# Planning Center API Client (Singleton)
# ==============================================================================
#
# Purpose:
#   Provides a shared, reusable Planning Center API client instance for all
#   sync scripts. Uses the singleton pattern to avoid creating multiple
#   connections and to centralize authentication.
#
# Usage:
#   require_relative "pco_client"
#   api = PCO::Client.api
#   api.people.v2.people.get(per_page: 100)
#
# Environment Variables:
#   ROL_PLANNING_CENTER_CLIENT_ID  - Personal Access Token ID
#   ROL_PLANNING_CENTER_SECRET     - Personal Access Token Secret
#
# API Documentation:
#   https://developer.planning.center/docs
#
# ==============================================================================

require "pco_api"

module PCO
  class Client
    def self.instance
      @instance ||= PCO::API.new(
        basic_auth_token: ENV["ROL_PLANNING_CENTER_CLIENT_ID"],
        basic_auth_secret: ENV["ROL_PLANNING_CENTER_SECRET"]
      )
    end

    def self.api
      instance
    end
  end
end
