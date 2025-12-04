# frozen_string_literal: true

# ==============================================================================
# Webhook Logger
# ==============================================================================
#
# Logs all incoming webhooks to DynamoDB with comprehensive metadata for
# auditing, debugging, and analytics.
#
# Table Schema:
#   - id: ULID (sortable unique ID with embedded timestamp)
#   - received_at: ISO8601 timestamp in CST (America/Chicago)
#   - platform: Source platform (planningcenter, cloudflare)
#   - event_type: The webhook event type from the payload
#   - status: Processing status (received, verified, processed, failed)
#   - payload: Full JSON payload (stored as map)
#   - headers: Relevant request headers
#   - metadata: Additional context (Lambda request ID, IP, user agent)
#
# Indexes for flexible querying:
#   - PlatformDateIndex: Query by platform + date range
#   - EventTypeDateIndex: Query by event type + date range
#   - StatusDateIndex: Query by status + date range
#   - PlatformEventIndex: Query by platform:event combination
#   - DatePartitionIndex: Query all webhooks by date
#
# ==============================================================================

require "aws-sdk-dynamodb"
require "securerandom"
require "time"

class WebhookLogger
  # Platform name mappings for consistent naming
  PLATFORM_NAMES = {
    "pco" => "planningcenter",
    "cloudflare" => "cloudflare"
  }.freeze

  # CST timezone
  CST_TIMEZONE = "America/Chicago"

  # TTL: 90 days in seconds
  TTL_SECONDS = 90 * 24 * 60 * 60

  def initialize
    @table_name = ENV["WEBHOOK_LOGS_TABLE"]
    @dynamodb = Aws::DynamoDB::Client.new(region: ENV["AWS_REGION"] || "us-east-1")
  end

  # Log a webhook to DynamoDB
  #
  # @param source [String] Webhook source ("pco" or "cloudflare")
  # @param body [String] Raw request body
  # @param headers [Hash] Request headers (normalized to lowercase keys)
  # @param context [Hash] Lambda context and additional metadata
  # @param status [String] Processing status
  # @return [Hash] The logged item with its ID
  def log(source:, body:, headers:, context: {}, status: "received")
    return nil unless @table_name

    # Parse timestamps in CST
    now = Time.now.getlocal(cst_offset)
    received_at = now.iso8601(3) # Millisecond precision

    # Generate ULID-like ID (timestamp + random, sortable)
    id = generate_sortable_id(now)

    # Parse payload
    payload = parse_payload(body)

    # Extract event type from payload
    event_type = extract_event_type(source, payload, headers)

    # Normalize platform name
    platform = PLATFORM_NAMES[source.to_s.downcase] || source.to_s.downcase

    # Build composite keys for GSIs
    platform_event = "#{platform}:#{event_type}"
    date_partition = now.strftime("%Y-%m-%d")

    # Calculate TTL (90 days from now)
    ttl = (now + TTL_SECONDS).to_i

    # Build the item
    item = {
      # Primary key
      id: id,
      received_at: received_at,

      # Core attributes
      platform: platform,
      event_type: event_type,
      status: status,

      # Composite keys for GSIs
      platform_event: platform_event,
      date_partition: date_partition,

      # Timestamps
      received_at_unix: now.to_i,
      received_at_cst: now.strftime("%Y-%m-%d %H:%M:%S %Z"),
      ttl: ttl,

      # Request details
      payload: sanitize_for_dynamodb(payload),
      payload_raw: truncate_string(body, 400_000), # DynamoDB limit is 400KB
      payload_size_bytes: body.bytesize,

      # Headers (filtered to relevant ones)
      headers: extract_relevant_headers(headers),

      # Metadata
      metadata: build_metadata(context, headers)
    }

    # Write to DynamoDB
    @dynamodb.put_item(
      table_name: @table_name,
      item: item
    )

    puts "INFO: Logged webhook to DynamoDB: #{id}"
    item
  rescue Aws::DynamoDB::Errors::ServiceError => e
    puts "ERROR: Failed to log webhook to DynamoDB: #{e.message}"
    nil
  rescue => e
    puts "ERROR: Unexpected error logging webhook: #{e.message}"
    nil
  end

  # Update the status of a logged webhook
  #
  # @param id [String] The webhook log ID
  # @param received_at [String] The received_at timestamp (sort key)
  # @param status [String] New status
  # @param additional_data [Hash] Additional attributes to update
  def update_status(id:, received_at:, status:, additional_data: {})
    return unless @table_name

    update_expression = "SET #status = :status, updated_at = :updated_at"
    expression_values = {
      ":status" => status,
      ":updated_at" => Time.now.getlocal(cst_offset).iso8601(3)
    }
    expression_names = {
      "#status" => "status"
    }

    # Add additional data to update
    additional_data.each_with_index do |(key, value), index|
      update_expression += ", #attr#{index} = :val#{index}"
      expression_names["#attr#{index}"] = key.to_s
      expression_values[":val#{index}"] = value
    end

    @dynamodb.update_item(
      table_name: @table_name,
      key: { id: id, received_at: received_at },
      update_expression: update_expression,
      expression_attribute_names: expression_names,
      expression_attribute_values: expression_values
    )

    puts "INFO: Updated webhook status to '#{status}': #{id}"
  rescue Aws::DynamoDB::Errors::ServiceError => e
    puts "ERROR: Failed to update webhook status: #{e.message}"
  end

  # Query webhooks by platform and date range
  #
  # @param platform [String] Platform name
  # @param start_date [Time] Start of date range
  # @param end_date [Time] End of date range (optional, defaults to now)
  # @return [Array<Hash>] Matching webhook logs
  def query_by_platform(platform:, start_date:, end_date: nil)
    return [] unless @table_name

    end_date ||= Time.now.getlocal(cst_offset)

    @dynamodb.query(
      table_name: @table_name,
      index_name: "PlatformDateIndex",
      key_condition_expression: "platform = :platform AND received_at BETWEEN :start AND :end",
      expression_attribute_values: {
        ":platform" => platform,
        ":start" => start_date.iso8601,
        ":end" => end_date.iso8601
      }
    ).items
  rescue => e
    puts "ERROR: Query by platform failed: #{e.message}"
    []
  end

  # Query webhooks by event type and date range
  #
  # @param event_type [String] Event type
  # @param start_date [Time] Start of date range
  # @param end_date [Time] End of date range (optional)
  # @return [Array<Hash>] Matching webhook logs
  def query_by_event_type(event_type:, start_date:, end_date: nil)
    return [] unless @table_name

    end_date ||= Time.now.getlocal(cst_offset)

    @dynamodb.query(
      table_name: @table_name,
      index_name: "EventTypeDateIndex",
      key_condition_expression: "event_type = :event_type AND received_at BETWEEN :start AND :end",
      expression_attribute_values: {
        ":event_type" => event_type,
        ":start" => start_date.iso8601,
        ":end" => end_date.iso8601
      }
    ).items
  rescue => e
    puts "ERROR: Query by event type failed: #{e.message}"
    []
  end

  # Query webhooks by status and date range
  #
  # @param status [String] Processing status
  # @param start_date [Time] Start of date range
  # @param end_date [Time] End of date range (optional)
  # @return [Array<Hash>] Matching webhook logs
  def query_by_status(status:, start_date:, end_date: nil)
    return [] unless @table_name

    end_date ||= Time.now.getlocal(cst_offset)

    @dynamodb.query(
      table_name: @table_name,
      index_name: "StatusDateIndex",
      key_condition_expression: "#status = :status AND received_at BETWEEN :start AND :end",
      expression_attribute_names: { "#status" => "status" },
      expression_attribute_values: {
        ":status" => status,
        ":start" => start_date.iso8601,
        ":end" => end_date.iso8601
      }
    ).items
  rescue => e
    puts "ERROR: Query by status failed: #{e.message}"
    []
  end

  # Query webhooks by platform + event type combination
  #
  # @param platform [String] Platform name
  # @param event_type [String] Event type
  # @param start_date [Time] Start of date range
  # @param end_date [Time] End of date range (optional)
  # @return [Array<Hash>] Matching webhook logs
  def query_by_platform_event(platform:, event_type:, start_date:, end_date: nil)
    return [] unless @table_name

    end_date ||= Time.now.getlocal(cst_offset)
    platform_event = "#{platform}:#{event_type}"

    @dynamodb.query(
      table_name: @table_name,
      index_name: "PlatformEventIndex",
      key_condition_expression: "platform_event = :platform_event AND received_at BETWEEN :start AND :end",
      expression_attribute_values: {
        ":platform_event" => platform_event,
        ":start" => start_date.iso8601,
        ":end" => end_date.iso8601
      }
    ).items
  rescue => e
    puts "ERROR: Query by platform+event failed: #{e.message}"
    []
  end

  # Query all webhooks for a specific date
  #
  # @param date [Date, String] The date to query (YYYY-MM-DD format)
  # @return [Array<Hash>] Matching webhook logs
  def query_by_date(date:)
    return [] unless @table_name

    date_str = date.is_a?(Date) ? date.strftime("%Y-%m-%d") : date.to_s

    @dynamodb.query(
      table_name: @table_name,
      index_name: "DatePartitionIndex",
      key_condition_expression: "date_partition = :date",
      expression_attribute_values: {
        ":date" => date_str
      }
    ).items
  rescue => e
    puts "ERROR: Query by date failed: #{e.message}"
    []
  end

  private

  # Get CST timezone offset
  def cst_offset
    # CST is UTC-6, CDT is UTC-5
    # Use TZ environment variable for proper DST handling
    ENV["TZ"] = CST_TIMEZONE
    Time.now.strftime("%:z")
  end

  # Generate a sortable unique ID (ULID-like)
  # Format: timestamp_hex + random_hex
  def generate_sortable_id(time)
    timestamp_part = time.to_i.to_s(16).rjust(12, "0")
    random_part = SecureRandom.hex(8)
    "#{timestamp_part}-#{random_part}"
  end

  # Parse the webhook payload safely
  def parse_payload(body)
    return {} if body.nil? || body.empty?
    JSON.parse(body)
  rescue JSON::ParserError
    { raw: body[0..1000] } # Store truncated raw body if not JSON
  end

  # Extract the event type from the payload based on platform
  def extract_event_type(source, payload, headers)
    case source.to_s.downcase
    when "pco"
      # Planning Center includes event type in payload or headers
      payload.dig("data", 0, "attributes", "name") ||
        payload.dig("meta", "event") ||
        headers["x-pco-event"] ||
        payload["name"] ||
        "unknown"
    when "cloudflare"
      # Cloudflare Stream webhook event type
      payload.dig("event", "type") ||
        headers["cf-webhook-event"] ||
        payload["type"] ||
        "unknown"
    else
      "unknown"
    end
  end

  # Extract relevant headers for logging
  def extract_relevant_headers(headers)
    relevant_keys = %w[
      content-type
      user-agent
      x-forwarded-for
      x-real-ip
      x-request-id
      x-pco-signature
      x-pco-event
      x-pco-delivery
      cf-webhook-signature
      cf-connecting-ip
      cf-ray
      cf-webhook-event
    ]

    headers.select { |k, _| relevant_keys.include?(k.downcase) }
  end

  # Build metadata from Lambda context and request
  def build_metadata(context, headers)
    {
      aws_request_id: context[:aws_request_id],
      function_name: context[:function_name],
      function_version: context[:function_version],
      log_group_name: context[:log_group_name],
      log_stream_name: context[:log_stream_name],
      source_ip: headers["x-forwarded-for"]&.split(",")&.first&.strip ||
                 headers["x-real-ip"] ||
                 headers["cf-connecting-ip"],
      user_agent: headers["user-agent"],
      stage: ENV["STAGE"]
    }.compact
  end

  # Truncate string to fit DynamoDB limits
  def truncate_string(str, max_bytes)
    return str if str.bytesize <= max_bytes
    str.byteslice(0, max_bytes - 100) + "... [TRUNCATED]"
  end

  # Sanitize payload for DynamoDB (handle empty strings, etc.)
  def sanitize_for_dynamodb(obj)
    case obj
    when Hash
      obj.each_with_object({}) do |(k, v), result|
        sanitized = sanitize_for_dynamodb(v)
        result[k.to_s] = sanitized unless sanitized.nil?
      end
    when Array
      obj.map { |v| sanitize_for_dynamodb(v) }.compact
    when String
      obj.empty? ? nil : obj
    when Numeric, TrueClass, FalseClass
      obj
    else
      obj.to_s.empty? ? nil : obj.to_s
    end
  end
end
