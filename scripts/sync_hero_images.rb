#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync groups from Planning Center Groups to the website
# Usage: ruby sync_groups.rb

require_relative "pco_client"
require "json"
require "time"

OUTPUT_PATH = File.join(__dir__, "..", "src", "data", "groups.json")

def fetch_groups
  api = PCO::Client.api

  begin
    response = api.groups.v2.groups.get(
      filter: "enrollment_open",
      per_page: 50
    )

    groups = response["data"].map do |group|
      {
        id: group["id"],
        name: group["attributes"]["name"],
        description: group["attributes"]["description"],
        schedule: group["attributes"]["schedule"],
        enrollment_open: group["attributes"]["enrollment_open"]
      }
    end

    groups
  rescue => e
    puts "Error fetching groups: #{e.message}"
    []
  end
end

def write_groups(groups)
  # Ensure data directory exists
  data_dir = File.dirname(OUTPUT_PATH)
  Dir.mkdir(data_dir) unless Dir.exist?(data_dir)

  File.write(OUTPUT_PATH, JSON.pretty_generate({
    updated_at: Time.now.iso8601,
    groups: groups
  }))

  puts "Wrote #{groups.length} groups to #{OUTPUT_PATH}"
end

if __FILE__ == $0
  puts "Syncing groups from Planning Center..."
  groups = fetch_groups
  write_groups(groups)
  puts "Done!"
end
