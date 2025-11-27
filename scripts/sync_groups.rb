#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync groups from Planning Center Groups API
# Pulls listed/public groups with their leaders, images, and descriptions
# Usage: ruby sync_groups.rb

require_relative "pco_client"
require "json"
require "net/http"
require "uri"
require "openssl"
require "time"

# Set timezone to Central Time
ENV['TZ'] = 'America/Chicago'
Time.zone = 'America/Chicago' if Time.respond_to?(:zone=)

# Force immediate output
$stdout.sync = true
$stderr.sync = true

GROUPS_DIR = File.join(__dir__, "..", "public", "groups")
OUTPUT_PATH = File.join(__dir__, "..", "src", "data", "groups.json")

def sync_groups
  puts "INFO: Starting groups sync from Planning Center"

  # Create groups directory if it doesn't exist
  Dir.mkdir(GROUPS_DIR) unless Dir.exist?(GROUPS_DIR)

  api = PCO::Client.api
  groups_data = []

  begin
    puts "INFO: Fetching listed groups..."

    # Fetch all groups that are visible in Church Center (listed)
    offset = 0
    all_groups = []

    loop do
      response = api.groups.v2.groups.get(
        per_page: 100,
        offset: offset,
        where: { church_center_visible: true }
      )

      groups = response["data"] || []
      break if groups.empty?

      all_groups.concat(groups)
      offset += 100
      break unless response.dig("links", "next")
    end

    puts "INFO: Found #{all_groups.length} listed groups"

    all_groups.each do |group|
      group_id = group["id"]
      attrs = group["attributes"]

      name = attrs["name"]
      description = attrs["description"] || ""
      header_image = attrs["header_image"]&.dig("original")
      schedule = attrs["schedule"] || ""
      contact_email = attrs["contact_email"]

      puts "INFO: Processing group: #{name} (ID: #{group_id})"

      # Generate slug from name
      slug = name.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')

      # Download header image
      image_filename = nil
      has_image = false
      if header_image && !header_image.empty?
        image_filename = "#{slug}_header"
        has_image = download_image(header_image, image_filename)
      end

      # Fetch group leaders (memberships with role = "leader")
      leaders = []
      begin
        memberships_response = api.groups.v2.groups[group_id].memberships.get(
          per_page: 100,
          where: { role: "leader" },
          include: "person"
        )

        included_people = memberships_response["included"] || []
        people_by_id = included_people.each_with_object({}) do |person, hash|
          hash[person["id"]] = person if person["type"] == "Person"
        end

        # First pass: collect all leader data (need to fetch from People API for gender)
        raw_leaders = []
        memberships = memberships_response["data"] || []
        memberships.each do |membership|
          person_id = membership.dig("relationships", "person", "data", "id")
          person = people_by_id[person_id]

          if person
            person_attrs = person["attributes"]

            # Fetch full person details from People API to get gender
            gender = nil
            begin
              people_response = api.people.v2.people[person_id].get
              gender = people_response.dig("data", "attributes", "gender")
            rescue => e
              puts "WARNING: Could not fetch gender for person #{person_id}"
            end

            raw_leaders << {
              id: person_id,
              firstName: person_attrs["first_name"],
              lastName: person_attrs["last_name"],
              gender: gender,
              avatar_url: person_attrs["avatar_url"]
            }
          end
        end

        # Second pass: detect and combine couples (same last name, different genders)
        processed_ids = Set.new
        raw_leaders.each do |leader|
          next if processed_ids.include?(leader[:id])

          # Look for a spouse (same last name, different gender)
          spouse = raw_leaders.find do |other|
            other[:id] != leader[:id] &&
            !processed_ids.include?(other[:id]) &&
            other[:lastName]&.downcase == leader[:lastName]&.downcase &&
            other[:gender] != leader[:gender]
          end

          if spouse
            # Found a couple - combine them
            processed_ids.add(leader[:id])
            processed_ids.add(spouse[:id])

            # Determine male/female
            male = leader[:gender]&.downcase == "male" ? leader : spouse
            female = leader[:gender]&.downcase == "male" ? spouse : leader

            # Use male's photo
            leader_filename = "#{slug}_leader_#{male[:id]}"
            leader_has_photo = false
            if male[:avatar_url] && !male[:avatar_url].include?('no-photo')
              leader_has_photo = download_image(male[:avatar_url], leader_filename)
            end

            combined_name = "#{male[:firstName]} & #{female[:firstName]} #{male[:lastName]}"

            leaders << {
              id: "#{male[:id]}_#{female[:id]}",
              name: combined_name,
              firstName: male[:firstName],
              lastName: male[:lastName],
              image: leader_has_photo ? "/groups/#{leader_filename}.jpg" : nil,
              hasPhoto: leader_has_photo,
              isCouple: true
            }

            puts "INFO: Combined couple leaders: #{combined_name}"
          else
            # Single leader
            processed_ids.add(leader[:id])

            leader_filename = "#{slug}_leader_#{leader[:id]}"
            leader_has_photo = false
            if leader[:avatar_url] && !leader[:avatar_url].include?('no-photo')
              leader_has_photo = download_image(leader[:avatar_url], leader_filename)
            end

            leader_name = "#{leader[:firstName]} #{leader[:lastName]}"

            leaders << {
              id: leader[:id],
              name: leader_name,
              firstName: leader[:firstName],
              lastName: leader[:lastName],
              image: leader_has_photo ? "/groups/#{leader_filename}.jpg" : nil,
              hasPhoto: leader_has_photo,
              isCouple: false
            }
          end
        end

        puts "INFO: Found #{leaders.length} leader entries for #{name} (from #{raw_leaders.length} people)"
      rescue => e
        puts "WARNING: Failed to fetch leaders for group #{group_id}: #{e.message}"
      end

      groups_data << {
        id: group_id,
        name: name,
        slug: slug,
        description: description,
        schedule: schedule,
        contactEmail: contact_email,
        headerImage: has_image ? "/groups/#{image_filename}.jpg" : nil,
        hasHeaderImage: has_image,
        leaders: leaders
      }
    end

    # Sort groups alphabetically by name
    groups_data.sort_by! { |g| g[:name].downcase }

    puts "SUCCESS: Processed #{groups_data.length} groups"

    # Write groups data JSON
    data_dir = File.dirname(OUTPUT_PATH)
    Dir.mkdir(data_dir) unless Dir.exist?(data_dir)

    File.write(OUTPUT_PATH, JSON.pretty_generate({
      updated_at: Time.now.iso8601,
      groups: groups_data
    }))
    puts "INFO: Generated groups.json"

    return groups_data.any?

  rescue => e
    puts "ERROR syncing groups: #{e.message}"
    puts "ERROR class: #{e.class}"
    puts e.backtrace.first(10).join("\n")
    return false
  end
end

def download_image(url, filename)
  uri = URI(url)
  redirect_limit = 5

  redirect_limit.times do
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.open_timeout = 30
    http.read_timeout = 60

    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)

    case response
    when Net::HTTPSuccess
      content_type = response['content-type'] || ''

      if content_type.include?('text/html')
        puts "WARNING: Got HTML instead of image for #{filename}"
        return false
      end

      file_path = File.join(GROUPS_DIR, "#{filename}.jpg")
      File.binwrite(file_path, response.body)
      puts "INFO: Downloaded image: #{filename}.jpg (#{response.body.bytesize} bytes)"
      return true

    when Net::HTTPRedirection
      new_location = response['location']
      uri = URI(new_location)

    else
      puts "WARNING: Failed to download #{filename}: HTTP #{response.code}"
      return false
    end
  end

  puts "WARNING: Too many redirects for #{filename}"
  false
end

if __FILE__ == $0
  puts "Syncing groups from Planning Center..."
  success = sync_groups
  if success
    puts "Done!"
    exit 0
  else
    puts "Failed to sync groups (or no groups found)"
    exit 0
  end
end
