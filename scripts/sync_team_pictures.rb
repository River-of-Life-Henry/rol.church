#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync events from Planning Center Calendar to the website
# Usage: ruby sync_events.rb

require_relative "pco_client"
require "json"
require "time"

OUTPUT_PATH = File.join(__dir__, "..", "src", "data", "events.json")

def fetch_upcoming_events
  api = PCO::Client.api

  # Fetch events from Planning Center Calendar
  # Adjust the endpoint based on your PCO setup
  begin
    response = api.calendar.v2.events.get(
      filter: "upcoming",
      per_page: 50,
      include: "event_instances"
    )

    events = response["data"].map do |event|
      {
        id: event["id"],
        name: event["attributes"]["name"],
        description: event["attributes"]["description"],
        starts_at: event["attributes"]["starts_at"],
        ends_at: event["attributes"]["ends_at"],
        visible_in_church_center: event["attributes"]["visible_in_church_center"]
      }
    end

    events.select { |e| e[:visible_in_church_center] }
  rescue => e
    puts "Error fetching events: #{e.message}"
    []
  end
end

def write_events(events)
  # Ensure data directory exists
  data_dir = File.dirname(OUTPUT_PATH)
  Dir.mkdir(data_dir) unless Dir.exist?(data_dir)

  File.write(OUTPUT_PATH, JSON.pretty_generate({
    updated_at: Time.now.iso8601,
    events: events
  }))

  puts "Wrote #{events.length} events to #{OUTPUT_PATH}"
end

if __FILE__ == $0
  puts "Syncing events from Planning Center..."
  events = fetch_upcoming_events
  write_events(events)
  puts "Done!"
end
