#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Sync Events from Planning Center Calendar
# ==============================================================================
#
# Purpose:
#   Fetches upcoming events from Planning Center Calendar API and generates
#   JSON data files for the website. Also identifies the next "Featured"
#   event for the hello bar notification.
#
# Usage:
#   ruby sync_events.rb
#   bundle exec ruby sync_events.rb
#
# Output Files:
#   src/data/events.json          - All upcoming events (next 12 weeks)
#   src/data/featured_event.json  - Next featured event for hello bar
#
# Performance:
#   - Fetches event instances first (paginated, 100 per page)
#   - Deduplicates event IDs to minimize API calls
#   - Fetches event details in parallel (8 threads)
#   - Typical runtime: 3-5 seconds
#
# Filtering:
#   - Only events from the default "River of Life" calendar
#   - Excludes "Reminders" and "Regular Services" calendars
#   - Only Church Center-visible events
#   - Excludes events with "Hidden" tag
#   - Limited to next 12 weeks
#
# Alerts:
#   - Outputs ALERT: prefix for issues that need attention
#   - Missing featured event
#   - Featured event without description or image
#
# Environment Variables:
#   ROL_PLANNING_CENTER_CLIENT_ID  - Planning Center API token ID
#   ROL_PLANNING_CENTER_SECRET     - Planning Center API token secret
#
# ==============================================================================

require_relative "pco_client"
require "json"
require "time"
require "parallel"

# Set timezone to Central Time
ENV['TZ'] = 'America/Chicago'
Time.zone = 'America/Chicago' if Time.respond_to?(:zone=)

# Force immediate output
$stdout.sync = true
$stderr.sync = true

OUTPUT_PATH = File.join(__dir__, "..", "src", "data", "events.json")
FEATURED_OUTPUT_PATH = File.join(__dir__, "..", "src", "data", "featured_event.json")

# Parallel threads for API calls
PARALLEL_THREADS = 8

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
  errors = []

  begin
    now = Time.now
    twelve_weeks_later = now + (12 * 7 * 24 * 60 * 60)

    puts "INFO: Fetching future events (next 12 weeks)..."

    # Step 1: Fetch all event instances with included event data (paginated)
    # Include event data so we can filter by calendar
    all_instances = []
    included_events = {}
    offset = 0
    loop do
      begin
        response = api.calendar.v2.event_instances.get(
          per_page: 100,
          offset: offset,
          filter: "future,church_center_visible",
          order: "starts_at",
          include: "event"
        )

        instances = response["data"] || []
        break if instances.empty?

        # Build a lookup of included events by ID
        (response["included"] || []).each do |item|
          if item["type"] == "Event"
            included_events[item["id"]] = item
          end
        end

        # Filter to 12 weeks, default calendar only
        instances.each do |instance|
          attrs = instance["attributes"]
          starts_at = attrs["starts_at"]
          next if starts_at.nil?

          event_time = Time.parse(starts_at) rescue nil
          next if event_time.nil? || event_time > twelve_weeks_later

          # Filter by calendar - only include events from the default "River of Life" calendar
          event_id = instance.dig("relationships", "event", "data", "id")
          event_data = included_events[event_id]
          calendar_id = event_data&.dig("relationships", "calendar", "data", "id")
          next unless calendar_id == "default"

          all_instances << instance
        end

        offset += 100
        break unless response.dig("links", "next")
        break if all_instances.length >= 100 # Limit
      rescue => e
        errors << "Fetching instances page #{offset}: #{e.message}"
        break
      end
    end

    puts "INFO: Found #{all_instances.length} event instances, fetching details in parallel..."

    # Step 2: Get unique event IDs to fetch (avoid duplicate API calls)
    event_ids = all_instances.map { |i| i.dig("relationships", "event", "data", "id") }.compact.uniq
    puts "INFO: Fetching details for #{event_ids.length} unique events..."

    # Step 3: Fetch event details in parallel
    event_details = {}
    mutex = Mutex.new

    Parallel.each(event_ids, in_threads: PARALLEL_THREADS) do |event_id|
      begin
        event_response = api.calendar.v2.events[event_id].get(include: "tags")
        mutex.synchronize do
          event_details[event_id] = event_response
        end
      rescue => e
        mutex.synchronize do
          errors << "Fetching event #{event_id}: #{e.message}"
          event_details[event_id] = nil
        end
      end
    end

    puts "INFO: Fetched #{event_details.compact.length} event details"

    # Step 4: Build events array using cached details
    all_instances.each do |instance|
      attrs = instance["attributes"]
      starts_at = attrs["starts_at"]
      ends_at = attrs["ends_at"]
      all_day = attrs["all_day_event"] || false

      event_id = instance.dig("relationships", "event", "data", "id")
      tags = []
      visible_in_church_center = true
      is_featured = false
      event_image_url = nil
      registration_url = nil
      summary = nil

      if event_id && event_details[event_id]
        event_response = event_details[event_id]
        event_attrs = event_response.dig("data", "attributes") || {}
        visible_in_church_center = event_attrs["visible_in_church_center"] != false

        is_featured = event_attrs["featured"] == true

        if is_featured
          event_image_url = event_attrs["image_url"]
          registration_url = event_attrs["registration_url"]
          summary = event_attrs["summary"]
        end

        included = event_response["included"] || []
        tags = included.select { |i| i["type"] == "Tag" }.map { |t| t.dig("attributes", "name") }.compact
      end

      # Skip events not visible in Church Center or with Hidden tag
      next unless visible_in_church_center
      next if tags.any? { |t| t.downcase.include?("hidden") }

      event_name = attrs["name"] || "Untitled Event"
      slug = event_name.downcase.gsub(/[^a-z0-9\s-]/, '').gsub(/\s+/, '-').gsub(/-+/, '-').gsub(/^-|-$/, '')

      events << {
        id: instance["id"],
        name: event_name,
        slug: slug,
        description: attrs["description"] || "",
        summary: summary,
        startsAt: to_chicago_time(starts_at),
        endsAt: to_chicago_time(ends_at),
        location: attrs["location"] || "",
        allDay: all_day,
        tags: tags,
        featured: is_featured,
        imageUrl: event_image_url,
        registrationUrl: registration_url
      }
    end

    # Sort by start date
    events.sort_by! { |e| e[:startsAt] }

    puts "SUCCESS: Found #{events.length} upcoming events"

    # Report any errors encountered
    if errors.any?
      puts "WARN: #{errors.length} non-fatal errors during sync:"
      errors.first(5).each { |e| puts "  - #{e}" }
    end

    # Find the next featured event (first one in sorted list that is featured)
    featured_event = events.find { |e| e[:featured] }
    if featured_event
      puts "INFO: Featured event found: #{featured_event[:name]}"

      # Validate featured event has required content - output as ALERT for email
      alerts = []

      desc = featured_event[:description] || ""
      summary_text = featured_event[:summary] || ""
      combined_text = (desc + summary_text).gsub(/<[^>]*>/, '').strip
      if combined_text.empty?
        alerts << "no description"
      elsif combined_text.length < 50
        alerts << "very short description (#{combined_text.length} chars)"
      end

      if featured_event[:imageUrl].nil? || featured_event[:imageUrl].strip.empty?
        alerts << "no header image"
      end

      if alerts.any?
        # Output as ALERT: prefix so sync_all.rb can capture it for email
        puts "ALERT: Featured event '#{featured_event[:name]}' has issues: #{alerts.join(', ')}. Please update in Planning Center Calendar."
      end
    else
      # Output as ALERT: prefix so sync_all.rb can capture it for email
      puts "ALERT: No featured event is set in Planning Center. The hello bar will be empty. Please mark an upcoming event as 'Featured' in Calendar."
    end

    # Write events data JSON
    data_dir = File.dirname(OUTPUT_PATH)
    Dir.mkdir(data_dir) unless Dir.exist?(data_dir)

    File.write(OUTPUT_PATH, JSON.pretty_generate({
      updated_at: Time.now.iso8601,
      events: events
    }))
    puts "INFO: Generated events.json"

    # Write featured event JSON (for hello bar)
    File.write(FEATURED_OUTPUT_PATH, JSON.pretty_generate({
      updated_at: Time.now.iso8601,
      event: featured_event
    }))
    puts "INFO: Generated featured_event.json"

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
