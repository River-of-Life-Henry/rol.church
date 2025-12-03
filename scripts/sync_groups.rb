#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Sync Groups from Planning Center Groups
# ==============================================================================
#
# Purpose:
#   Fetches ministry groups from Planning Center Groups API with their leaders,
#   images, and descriptions. Downloads and optimizes header images and leader
#   avatars for the website.
#
# Usage:
#   ruby sync_groups.rb
#   bundle exec ruby sync_groups.rb
#
# Output Files:
#   src/data/groups.json       - Group data with leaders and metadata
#   public/groups/*.jpg        - Optimized header images and leader avatars
#   public/groups/*.webp       - WebP versions of all images
#
# Performance:
#   - Fetches groups paginated (100 per page)
#   - Processes groups in parallel (6 threads)
#   - Fetches person details in parallel (4 threads per group)
#   - Downloads images via ImageUtils module
#   - Typical runtime: 10-30 seconds depending on image downloads
#
# Features:
#   - Smart couple detection (same last name, different genders)
#   - Combined display names for couples ("John & Jane Smith")
#   - Custom bio extraction from Planning Center "Website" tab fields
#   - Skips groups with no leaders
#
# Filtering:
#   - Only Church Center-visible groups
#   - Only groups with at least one leader
#
# Environment Variables:
#   ROL_PLANNING_CENTER_CLIENT_ID  - Planning Center API token ID
#   ROL_PLANNING_CENTER_SECRET     - Planning Center API token secret
#
# ==============================================================================

require_relative "pco_client"
require_relative "image_utils"
require "json"
require "net/http"
require "uri"
require "openssl"
require "time"
require "parallel"
require "set"

# Set timezone to Central Time
ENV['TZ'] = 'America/Chicago'
Time.zone = 'America/Chicago' if Time.respond_to?(:zone=)

# Force immediate output
$stdout.sync = true
$stderr.sync = true

GROUPS_DIR = File.join(__dir__, "..", "public", "groups")
OUTPUT_PATH = File.join(__dir__, "..", "src", "data", "groups.json")

# Website custom tab ID for bio field
WEBSITE_TAB_ID = "239509"

# Parallel threads
PARALLEL_THREADS = 6

# Fetch bio from Planning Center People custom fields
def fetch_person_bio(api, person_id)
  bio = nil

  begin
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

    # Extract bio from website tab fields
    field_data.each do |fd|
      field_def_id = fd.dig("relationships", "field_definition", "data", "id")
      field_def = field_defs_by_id[field_def_id]
      next unless field_def

      field_name = field_def.dig("attributes", "name")&.downcase
      tab_id = field_def.dig("relationships", "tab", "data", "id")
      value = fd.dig("attributes", "value")

      if tab_id == WEBSITE_TAB_ID && field_name == "bio"
        bio = value
        break
      end
    end
  rescue => e
    # Non-fatal, continue without bio
  end

  bio
end

# Fetch person details (gender, bio) - called in parallel
def fetch_person_details(api, person_id)
  gender = nil
  bio = nil

  begin
    people_response = api.people.v2.people[person_id].get
    gender = people_response.dig("data", "attributes", "gender")
  rescue => e
    # Non-fatal
  end

  bio = fetch_person_bio(api, person_id)

  { gender: gender, bio: bio }
end

def sync_groups
  puts "INFO: Starting groups sync from Planning Center"

  # Create groups directory if it doesn't exist
  Dir.mkdir(GROUPS_DIR) unless Dir.exist?(GROUPS_DIR)

  api = PCO::Client.api
  groups_data = []
  errors = []

  begin
    puts "INFO: Fetching listed groups..."

    # Fetch all groups that are visible in Church Center (listed)
    offset = 0
    all_groups = []

    loop do
      begin
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
      rescue => e
        errors << "Fetching groups page #{offset}: #{e.message}"
        break
      end
    end

    puts "INFO: Found #{all_groups.length} listed groups"

    # Process groups in parallel
    mutex = Mutex.new

    Parallel.each(all_groups, in_threads: PARALLEL_THREADS) do |group|
      begin
        group_data = process_group(api, group, mutex, errors)
        if group_data
          mutex.synchronize { groups_data << group_data }
        end
      rescue => e
        mutex.synchronize { errors << "Processing group #{group['id']}: #{e.message}" }
      end
    end

    # Sort groups alphabetically by name
    groups_data.sort_by! { |g| g[:name].downcase }

    puts "SUCCESS: Processed #{groups_data.length} groups"

    # Report any errors
    if errors.any?
      puts "WARN: #{errors.length} non-fatal errors during sync:"
      errors.first(5).each { |e| puts "  - #{e}" }
    end

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

def process_group(api, group, mutex, errors)
  group_id = group["id"]
  attrs = group["attributes"]

  name = attrs["name"]
  description = attrs["description"] || ""
  header_image = attrs["header_image"]&.dig("original")
  schedule = attrs["schedule"] || ""
  contact_email = attrs["contact_email"]

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

    memberships = memberships_response["data"] || []
    person_ids = memberships.map { |m| m.dig("relationships", "person", "data", "id") }.compact

    # Fetch person details (gender, bio) in parallel
    person_details = {}
    Parallel.each(person_ids, in_threads: [person_ids.length, 4].min) do |person_id|
      details = fetch_person_details(api, person_id)
      mutex.synchronize { person_details[person_id] = details }
    end

    # Build raw leaders list
    raw_leaders = []
    memberships.each do |membership|
      person_id = membership.dig("relationships", "person", "data", "id")
      person = people_by_id[person_id]

      if person
        person_attrs = person["attributes"]
        details = person_details[person_id] || {}

        raw_leaders << {
          id: person_id,
          firstName: person_attrs["first_name"],
          lastName: person_attrs["last_name"],
          gender: details[:gender],
          avatar_url: person_attrs["avatar_url"],
          bio: details[:bio]
        }
      end
    end

    # Detect and combine couples (same last name, different genders)
    # This creates combined entries like "John & Jane Smith" for married couples
    # who both serve as group leaders. Matching criteria:
    #   1. Same last name (case-insensitive)
    #   2. Different genders
    #   3. Neither already processed
    processed_ids = Set.new
    raw_leaders.each do |leader|
      next if processed_ids.include?(leader[:id])

      # Look for potential spouse among remaining unprocessed leaders
      spouse = raw_leaders.find do |other|
        other[:id] != leader[:id] &&
        !processed_ids.include?(other[:id]) &&
        other[:lastName]&.downcase == leader[:lastName]&.downcase &&
        other[:gender] != leader[:gender]
      end

      if spouse
        # Mark both as processed to prevent duplicate entries
        processed_ids.add(leader[:id])
        processed_ids.add(spouse[:id])

        # Order as "Husband & Wife LastName" - use male's photo as couple photo
        male = leader[:gender]&.downcase == "male" ? leader : spouse
        female = leader[:gender]&.downcase == "male" ? spouse : leader

        leader_filename = "#{slug}_leader_#{male[:id]}"
        leader_has_photo = false
        if male[:avatar_url] && !male[:avatar_url].include?('no-photo')
          leader_has_photo = download_image(male[:avatar_url], leader_filename, type: :leader)
        end

        combined_name = "#{male[:firstName]} & #{female[:firstName]} #{male[:lastName]}"
        couple_bio = male[:bio] || female[:bio]

        leaders << {
          id: "#{male[:id]}_#{female[:id]}",
          name: combined_name,
          firstName: male[:firstName],
          lastName: male[:lastName],
          image: leader_has_photo ? "/groups/#{leader_filename}.jpg" : nil,
          hasPhoto: leader_has_photo,
          isCouple: true,
          bio: couple_bio
        }
      else
        processed_ids.add(leader[:id])

        leader_filename = "#{slug}_leader_#{leader[:id]}"
        leader_has_photo = false
        if leader[:avatar_url] && !leader[:avatar_url].include?('no-photo')
          leader_has_photo = download_image(leader[:avatar_url], leader_filename, type: :leader)
        end

        leader_name = "#{leader[:firstName]} #{leader[:lastName]}"

        leaders << {
          id: leader[:id],
          name: leader_name,
          firstName: leader[:firstName],
          lastName: leader[:lastName],
          image: leader_has_photo ? "/groups/#{leader_filename}.jpg" : nil,
          hasPhoto: leader_has_photo,
          isCouple: false,
          bio: leader[:bio]
        }
      end
    end
  rescue => e
    mutex.synchronize { errors << "Fetching leaders for #{name}: #{e.message}" }
  end

  # Skip groups with no leaders
  if leaders.empty?
    return nil
  end

  {
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

def download_image(url, filename, type: :header)
  output_path = File.join(GROUPS_DIR, "#{filename}.jpg")
  success = ImageUtils.download_and_optimize(url, output_path, type: type)
  success
rescue => e
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
