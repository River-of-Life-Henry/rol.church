#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync events from Planning Center Calendar API
# Pulls upcoming events for the next 90 days
# Usage: ruby sync_events.rb

require_relative "pco_client"
require "json"
require "time"

# Set timezone to Central Time
ENV['TZ'] = 'America/Chicago'
Time.zone = 'America/Chicago' if Time.respond_to?(:zone=)

# Force immediate output
$stdout.sync = true
$stderr.sync = true

OUTPUT_PATH = File.join(__dir__, "..", "src", "data", "events.json")

# Convert ISO8601 time to Chicago timezone with offset
def to_chicago_time(iso_string)
  return nil if iso_string.nil?
  # Parse the time and convert to local (Chicago) timezone
  time = Time.parse(iso_string)
  chicago_time = time.getlocal
  # Include offset in output for proper JavaScript parsing
  chicago_time.strftime("%Y-%m-%dT%H:%M:%S%:z")
end

def sync_events
  puts "INFO: Starting events sync from Planning Center Calendar"

  api = PCO::Client.api
  events = []

  begin
    now = Time.now
    ninety_days_later = now + (90 * 24 * 60 * 60)

    puts "INFO: Fetching future events (next 90 days)..."

    # Fetch future event instances from Calendar API (only published/visible events)
    offset = 0
    loop do
      response = api.calendar.v2.event_instances.get(
        per_page: 100,
        offset: offset,
        filter: "future,church_center_visible",
        order: "starts_at"
      )

      instances = response["data"] || []
      break if instances.empty?

      instances.each do |instance|
        attrs = instance["attributes"]
        starts_at = attrs["starts_at"]
        ends_at = attrs["ends_at"]
        all_day = attrs["all_day_event"] || false

        next if starts_at.nil?

        # Parse and filter to next 90 days
        event_time = Time.parse(starts_at) rescue nil
        next if event_time.nil? || event_time > ninety_days_later

        # Get the event (parent) to check visibility and find tags
        event_id = instance.dig("relationships", "event", "data", "id")
        tags = []
        visible_in_church_center = true

        if event_id
          begin
            event_response = api.calendar.v2.events[event_id].get(include: "tags")
            event_attrs = event_response.dig("data", "attributes") || {}
            visible_in_church_center = event_attrs["visible_in_church_center"] != false

            included = event_response["included"] || []
            tags = included.select { |i| i["type"] == "Tag" }.map { |t| t.dig("attributes", "name") }.compact
          rescue
            # Continue if we can't get event details
          end
        end

        # Skip events not visible in Church Center or with Hidden tag
        next unless visible_in_church_center
        next if tags.any? { |t| t.downcase.include?("hidden") }

        events << {
          id: instance["id"],
          name: attrs["name"] || "Untitled Event",
          description: attrs["description"] || "",
          startsAt: to_chicago_time(starts_at),
          endsAt: to_chicago_time(ends_at),
          location: attrs["location"] || "",
          allDay: all_day,
          tags: tags
        }
      end

      offset += 100
      break unless response.dig("links", "next")
      break if events.length >= 100 # Limit to 100 events
    end

    # Sort by start date
    events.sort_by! { |e| e[:startsAt] }

    puts "SUCCESS: Found #{events.length} upcoming events"

    # Write events data JSON
    data_dir = File.dirname(OUTPUT_PATH)
    Dir.mkdir(data_dir) unless Dir.exist?(data_dir)

    File.write(OUTPUT_PATH, JSON.pretty_generate({
      updated_at: Time.now.iso8601,
      events: events
    }))
    puts "INFO: Generated events.json"

    return events.any?

  rescue => e
    puts "ERROR syncing events: #{e.message}"
    puts "ERROR class: #{e.class}"
    puts e.backtrace.first(10).join("\n")
    return false
  end
end

if __FILE__ == $0
  puts "Syncing events from Planning Center Calendar..."
  success = sync_events
  if success
    puts "Done!"
    exit 0
  else
    puts "Failed to sync events (or no events found)"
    exit 0
  end
end
