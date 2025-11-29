#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync team member profiles from Planning Center People API
# Pulls profile photos and custom field data (bio, title) for specified people
# Usage: ruby sync_team.rb

require_relative "pco_client"
require_relative "image_utils"
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

TEAM_DIR = File.join(__dir__, "..", "public", "team")
OUTPUT_PATH = File.join(__dir__, "..", "src", "data", "team.json")

# Team member definitions - Planning Center person IDs and their roles on the website
# To find a person's ID: go to Planning Center People, open the person's profile,
# the ID is in the URL: https://people.planningcenteronline.com/people/AC12345678
TEAM_MEMBERS = [
  {
    person_id: "140403632",  # Andrew Coffield
    role: "Senior Pastor",
    slug: "andrew_coffield",
    page: "/pastor"
  },
  {
    person_id: "159045547",  # Christopher Huff
    role: "Foundations Instructor",
    slug: "christopher_huff",
    page: "/next-steps/foundations"
  }
].freeze

# Custom field tab name where bio/title info is stored
WEBSITE_TAB_NAME = "Website - ROL.Church"

def sync_team
  puts "INFO: Starting team sync from Planning Center People"

  # Create team directory if it doesn't exist
  Dir.mkdir(TEAM_DIR) unless Dir.exist?(TEAM_DIR)

  api = PCO::Client.api
  team_data = []

  begin
    TEAM_MEMBERS.each do |member|
      person_id = member[:person_id]
      puts "INFO: Fetching person #{person_id} (#{member[:slug]})..."

      begin
        # Fetch person basic info
        person_response = api.people.v2.people[person_id].get
        person = person_response["data"]
        attrs = person["attributes"]

        first_name = attrs["first_name"]
        last_name = attrs["last_name"]
        avatar_url = attrs["avatar"]

        puts "INFO: Found: #{first_name} #{last_name}"

        # Download profile photo
        photo_filename = member[:slug]
        has_photo = false
        if avatar_url && !avatar_url.include?('no-photo')
          has_photo = download_image(avatar_url, photo_filename)
        end

        # Fetch custom field data from the website tab
        bio = nil
        custom_title = nil
        spouse_name = nil

        begin
          # Get field data for this person with field definitions included
          field_data_response = api.people.v2.people[person_id].field_data.get(
            per_page: 100,
            include: "field_definition"
          )
          field_data = field_data_response["data"] || []
          included = field_data_response["included"] || []

          # Build lookup for field definitions
          field_defs_by_id = {}
          included.each do |item|
            if item["type"] == "FieldDefinition"
              field_defs_by_id[item["id"]] = item
            end
          end

          # Extract values from website tab fields
          field_data.each do |fd|
            field_def_id = fd.dig("relationships", "field_definition", "data", "id")
            field_def = field_defs_by_id[field_def_id]
            next unless field_def

            field_name = field_def.dig("attributes", "name")&.downcase
            tab_id = field_def.dig("relationships", "tab", "data", "id")
            value = fd.dig("attributes", "value")

            # Only use fields from the website tab (ID: 239509)
            if tab_id == "239509"
              case field_name
              when "bio"
                bio = value
              when "position title"
                custom_title = value
              end
            end
          end

          puts "INFO: Bio: #{bio&.length || 0} chars - #{bio&.slice(0, 50)}..."
          puts "INFO: Position Title: #{custom_title || 'not set'}"
        rescue => e
          puts "WARN: Could not fetch custom fields: #{e.message}"
          puts e.backtrace.first(3).join("\n")
        end

        # Build display name (include spouse if available)
        display_name = if spouse_name && !spouse_name.strip.empty?
          "#{first_name} & #{spouse_name} #{last_name}"
        else
          "#{first_name} #{last_name}"
        end

        team_data << {
          id: person_id,
          slug: member[:slug],
          role: custom_title || member[:role],
          defaultRole: member[:role],
          page: member[:page],
          firstName: first_name,
          lastName: last_name,
          spouseName: spouse_name,
          displayName: display_name,
          bio: bio,
          image: has_photo ? "/team/#{photo_filename}.jpg" : nil,
          hasPhoto: has_photo
        }

      rescue => e
        puts "ERROR: Failed to fetch person #{person_id}: #{e.message}"
      end
    end

    puts "SUCCESS: Processed #{team_data.length} team members"

    # Write team data JSON
    data_dir = File.dirname(OUTPUT_PATH)
    Dir.mkdir(data_dir) unless Dir.exist?(data_dir)

    File.write(OUTPUT_PATH, JSON.pretty_generate({
      updated_at: Time.now.iso8601,
      team: team_data
    }))
    puts "INFO: Generated team.json"

    return team_data.any?

  rescue => e
    puts "ERROR syncing team: #{e.message}"
    puts "ERROR class: #{e.class}"
    puts e.backtrace.first(10).join("\n")
    return false
  end
end

def download_image(url, filename)
  output_path = File.join(TEAM_DIR, "#{filename}.jpg")
  success = ImageUtils.download_and_optimize(url, output_path, type: :team)

  if success
    puts "INFO: Processed team image: #{filename}.jpg"
  else
    puts "WARNING: Failed to download/optimize #{filename}"
  end

  success
end

if __FILE__ == $0
  puts "Syncing team from Planning Center People..."
  success = sync_team
  if success
    puts "Done!"
    exit 0
  else
    puts "Failed to sync team (or no team members found)"
    exit 0
  end
end
