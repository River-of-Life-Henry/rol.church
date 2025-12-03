# frozen_string_literal: true

# ==============================================================================
# GitHub Actions Workflow Trigger
# ==============================================================================
#
# Triggers the daily-sync.yml workflow via GitHub's workflow_dispatch API.
# Passes the webhook source so the workflow can run targeted syncs:
#   - pco: Run all Planning Center syncs (events, groups, team, etc.)
#   - cloudflare: Run only Cloudflare video sync
#
# ==============================================================================

require "net/http"
require "uri"
require "json"

module GithubTrigger
  GITHUB_API = "https://api.github.com"
  WORKFLOW_FILE = "daily-sync.yml"

  class << self
    # Trigger the sync workflow via workflow_dispatch
    #
    # @param triggered_by [String] Source of the webhook ("pco" or "cloudflare")
    # @return [Hash] { success: Boolean, error: String (optional) }
    def dispatch_sync_workflow(triggered_by:)
      repo = ENV["GITHUB_REPO"]
      token = ENV["GITHUB_PAT"]

      unless repo
        return { success: false, error: "GITHUB_REPO not configured" }
      end

      unless token
        return { success: false, error: "GITHUB_PAT not configured" }
      end

      uri = URI("#{GITHUB_API}/repos/#{repo}/actions/workflows/#{WORKFLOW_FILE}/dispatches")

      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{token}"
      request["Accept"] = "application/vnd.github+json"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      request["User-Agent"] = "rol-webhooks"

      # Pass the source so workflow can run targeted sync
      request.body = JSON.generate({
        ref: "main",
        inputs: {
          triggered_by: triggered_by,
          sync_source: triggered_by  # "pco" or "cloudflare"
        }
      })

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.open_timeout = 10
        http.read_timeout = 30
        http.request(request)
      end

      # GitHub returns 204 No Content on success
      if response.code == "204"
        puts "INFO: Workflow dispatch successful (sync_source: #{triggered_by})"
        { success: true }
      else
        error_body = JSON.parse(response.body) rescue { "message" => response.body }
        error_msg = "GitHub API error: #{response.code} - #{error_body['message']}"
        puts "ERROR: #{error_msg}"
        { success: false, error: error_msg }
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      { success: false, error: "GitHub API timeout: #{e.message}" }
    rescue => e
      { success: false, error: "GitHub API error: #{e.message}" }
    end
  end
end
