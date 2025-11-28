#!/usr/bin/env ruby
# frozen_string_literal: true

# Run all sync scripts
# Usage: ruby sync_all.rb

require "bundler/setup"
require "dotenv"

# Load environment variables from .env file (for local development)
Dotenv.load(File.join(__dir__, ".env")) if File.exist?(File.join(__dir__, ".env"))

puts "=" * 50
puts "Planning Center Sync"
puts "=" * 50
puts

# Check for required environment variables
unless ENV["ROL_PLANNING_CENTER_CLIENT_ID"] && ENV["ROL_PLANNING_CENTER_SECRET"]
  puts "ERROR: Missing ROL_PLANNING_CENTER_CLIENT_ID or ROL_PLANNING_CENTER_SECRET environment variables"
  puts "Set these in GitHub Actions secrets or in scripts/.env for local development"
  exit 1
end

# Run each sync script
scripts = %w[
  sync_events.rb
  sync_groups.rb
  sync_hero_images.rb
  sync_team.rb
  sync_youtube.rb
]

scripts.each do |script|
  puts "\nRunning #{script}..."
  puts "-" * 30
  load File.join(__dir__, script)
end

puts
puts "=" * 50
puts "Sync complete!"
puts "=" * 50
