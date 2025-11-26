# frozen_string_literal: true

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
