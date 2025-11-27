#!/usr/bin/env ruby
# frozen_string_literal: true

# Sync team members from Planning Center People based on custom "Website - ROL.Church" tab
# Pulls people who have a Position Title set
# Couples in the same household are combined into one entry (if both have position titles)
# Usage: ruby sync_team.rb

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

TEAM_DIR = File.join(__dir__, "..", "public", "team")
OUTPUT_PATH = File.join(__dir__, "..", "src", "data", "team.json")

# Andrew Coffield's ID - always first (or his household)
PASTOR_ID = "140403632"

def sync_team
  puts "INFO: Starting team sync from Planning Center"

  # Create team directory if it doesn't exist
  Dir.mkdir(TEAM_DIR) unless Dir.exist?(TEAM_DIR)

  api = PCO::Client.api
  people_data = {} # person_id => { details }

  begin
    # First, get field definitions to find the Position Title and Bio field IDs
    puts "INFO: Fetching field definitions..."
    field_defs_response = api.people.v2.field_definitions.get(per_page: 100)
    field_definitions = field_defs_response["data"]

    position_title_field = field_definitions.find { |f| f["attributes"]["name"] == "Position Title" }
    bio_field = field_definitions.find { |f| f["attributes"]["name"] == "Bio" }

    if position_title_field.nil?
      puts "ERROR: Could not find 'Position Title' field definition"
      return false
    end

    position_title_field_id = position_title_field["id"]
    bio_field_id = bio_field&.dig("id")

    puts "INFO: Position Title field ID: #{position_title_field_id}"
    puts "INFO: Bio field ID: #{bio_field_id || 'not found'}"

    # Query field_data directly for Position Title entries
    puts "INFO: Fetching people with Position Title..."

    position_title_data = {}
    bio_data = {}

    # Get all Position Title field data
    offset = 0
    loop do
      field_data_response = api.people.v2.field_data.get(
        where: { field_definition_id: position_title_field_id },
        per_page: 100,
        offset: offset
      )

      entries = field_data_response["data"] || []
      break if entries.empty?

      entries.each do |fd|
        value = fd.dig("attributes", "value")
        person_id = fd.dig("relationships", "customizable", "data", "id")
        if value && !value.strip.empty? && person_id
          position_title_data[person_id] = value
        end
      end

      offset += 100
      break unless field_data_response.dig("links", "next")
    end

    puts "INFO: Found #{position_title_data.length} people with Position Title"

    # Get all Bio field data if available
    if bio_field_id
      offset = 0
      loop do
        field_data_response = api.people.v2.field_data.get(
          where: { field_definition_id: bio_field_id },
          per_page: 100,
          offset: offset
        )

        entries = field_data_response["data"] || []
        break if entries.empty?

        entries.each do |fd|
          value = fd.dig("attributes", "value")
          person_id = fd.dig("relationships", "customizable", "data", "id")
          if value && !value.strip.empty? && person_id
            bio_data[person_id] = value
          end
        end

        offset += 100
        break unless field_data_response.dig("links", "next")
      end
    end

    # Fetch each person's details and household info
    position_title_data.each do |person_id, position_title|
      puts "INFO: Fetching person #{person_id}..."

      begin
        person_response = api.people.v2.people[person_id].get
        person = person_response["data"]
        attributes = person["attributes"]

        first_name = attributes["first_name"] || ""
        last_name = attributes["last_name"] || ""
        name = attributes["name"] || "#{first_name} #{last_name}"
        avatar_url = attributes["avatar"]
        gender = attributes["gender"]
        bio = bio_data[person_id] || ""

        # Get household memberships to find spouse
        household_response = api.people.v2.people[person_id].household_memberships.get(include: "household")
        households = household_response["included"] || []
        household_id = households.first&.dig("id")

        # Get other adults in this household
        spouse_id = nil
        if household_id
          members_response = api.people.v2.households[household_id].household_memberships.get(include: "person")
          members = members_response["included"] || []

          # Find other adults (not this person)
          members.each do |member|
            member_id = member["id"]
            member_child = member.dig("attributes", "child") || false
            next if member_id == person_id || member_child

            # Check if this person also has a position title
            if position_title_data.key?(member_id)
              spouse_id = member_id
              break
            end
          end
        end

        people_data[person_id] = {
          id: person_id,
          firstName: first_name,
          lastName: last_name,
          name: name,
          role: position_title,
          bio: bio,
          avatar_url: avatar_url,
          gender: gender,
          household_id: household_id,
          spouse_id: spouse_id,
          isPastor: person_id == PASTOR_ID
        }

        puts "INFO: Found team member: #{name} - #{position_title} (gender: #{gender}, household: #{household_id}, spouse: #{spouse_id})"

      rescue => e
        puts "WARNING: Failed to fetch person #{person_id}: #{e.message}"
      end
    end

    # Now combine couples and build final team list
    team_members = []
    processed_ids = Set.new

    people_data.each do |person_id, person|
      next if processed_ids.include?(person_id)

      spouse_id = person[:spouse_id]
      spouse = spouse_id ? people_data[spouse_id] : nil

      if spouse && !processed_ids.include?(spouse_id)
        # This is a couple - combine them
        processed_ids.add(person_id)
        processed_ids.add(spouse_id)

        # Determine who is male/female
        male = person[:gender]&.downcase == "male" ? person : spouse
        female = person[:gender]&.downcase == "male" ? spouse : person

        # Use male's photo
        filename = "#{male[:firstName]}_#{male[:lastName]}".downcase.gsub(/[^a-z_]/, '')
        filename = "couple_#{person_id}" if filename.empty?

        has_photo = false
        if male[:avatar_url] && !male[:avatar_url].include?('no-photo')
          has_photo = download_image(male[:avatar_url], filename)
        end

        # Combine names: "David & Tiffany Plappert" or "Andrew & Chelsea Coffield"
        combined_name = "#{male[:firstName]} & #{female[:firstName]} #{male[:lastName]}"

        # Use only male's role and bio for couples
        combined_role = male[:role]
        combined_bio = male[:bio]

        # isPastor if either is the pastor
        is_pastor = male[:isPastor] || female[:isPastor]

        team_members << {
          id: "#{male[:id]}_#{female[:id]}",
          name: combined_name,
          firstName: male[:firstName],
          lastName: male[:lastName],
          role: combined_role,
          bio: combined_bio,
          filename: filename,
          image: "/team/#{filename}.jpg",
          hasPhoto: has_photo,
          isPastor: is_pastor,
          isCouple: true
        }

        puts "INFO: Combined couple: #{combined_name}"
      else
        # Single person (no spouse with position title)
        processed_ids.add(person_id)

        filename = "#{person[:firstName]}_#{person[:lastName]}".downcase.gsub(/[^a-z_]/, '')
        filename = "person_#{person_id}" if filename.empty?

        has_photo = false
        if person[:avatar_url] && !person[:avatar_url].include?('no-photo')
          has_photo = download_image(person[:avatar_url], filename)
        end

        team_members << {
          id: person_id,
          name: person[:name],
          firstName: person[:firstName],
          lastName: person[:lastName],
          role: person[:role],
          bio: person[:bio],
          filename: filename,
          image: "/team/#{filename}.jpg",
          hasPhoto: has_photo,
          isPastor: person[:isPastor],
          isCouple: false
        }
      end
    end

    # Sort: Pastor first, then by last name, then by first name
    pastor = team_members.find { |m| m[:isPastor] }
    others = team_members.reject { |m| m[:isPastor] }.sort_by { |m| [m[:lastName].downcase, m[:firstName].downcase] }

    sorted_team = [pastor, *others].compact

    puts "SUCCESS: Found #{sorted_team.length} team entries (#{people_data.length} people)"

    # Write team data JSON
    data_dir = File.dirname(OUTPUT_PATH)
    Dir.mkdir(data_dir) unless Dir.exist?(data_dir)

    File.write(OUTPUT_PATH, JSON.pretty_generate({
      updated_at: Time.now.iso8601,
      team: sorted_team
    }))
    puts "INFO: Generated team.json"

    return sorted_team.any?

  rescue => e
    puts "ERROR syncing team: #{e.message}"
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

      file_path = File.join(TEAM_DIR, "#{filename}.jpg")
      File.binwrite(file_path, response.body)
      puts "INFO: Downloaded team photo: #{filename}.jpg (#{response.body.bytesize} bytes)"
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
  puts "Syncing team from Planning Center..."
  success = sync_team
  if success
    puts "Done!"
    exit 0
  else
    puts "Failed to sync team (or no team members found)"
    exit 0
  end
end
