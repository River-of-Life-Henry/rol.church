# frozen_string_literal: true

# ==============================================================================
# ROL Church Webhook Handler
# ==============================================================================
#
# AWS Lambda function that receives webhooks from Planning Center and Cloudflare,
# verifies their signatures, and triggers the GitHub Actions sync workflow.
#
# Endpoints:
#   POST /webhook/pco        - Planning Center webhooks
#   POST /webhook/cloudflare - Cloudflare Stream webhooks
#   GET  /health             - Health check
#
# Environment Variables:
#   GITHUB_PAT              - GitHub Personal Access Token with Actions write permission
#   GITHUB_REPO             - Repository (e.g., "River-of-Life-Henry/rol.church")
#   PCO_WEBHOOK_SECRET      - Secret for verifying Planning Center signatures
#   CLOUDFLARE_WEBHOOK_SECRET - Secret for verifying Cloudflare signatures
#   STAGE                   - Deployment stage (dev/prod)
#
# ==============================================================================

require "json"
require_relative "lib/webhook_verifier"
require_relative "lib/github_trigger"
require_relative "lib/webhook_logger"

# Main webhook receiver handler
def receive(event:, context:)
  # Initialize webhook logger
  @webhook_logger = WebhookLogger.new

  # Extract source from path parameter
  source = event.dig("pathParameters", "source")&.downcase

  unless %w[pco cloudflare].include?(source)
    return response(400, { error: "Invalid webhook source. Use /webhook/pco or /webhook/cloudflare" })
  end

  # Get request body and headers
  body = event["body"] || ""
  headers = normalize_headers(event["headers"] || {})

  # Handle base64-encoded bodies (API Gateway sometimes encodes)
  if event["isBase64Encoded"]
    require "base64"
    body = Base64.decode64(body)
  end

  # Build Lambda context for logging
  lambda_context = {
    aws_request_id: context.aws_request_id,
    function_name: context.function_name,
    function_version: context.function_version,
    log_group_name: context.log_group_name,
    log_stream_name: context.log_stream_name
  }

  # Log webhook receipt to DynamoDB (status: received)
  log_entry = @webhook_logger.log(
    source: source,
    body: body,
    headers: headers,
    context: lambda_context,
    status: "received"
  )
  log_id = log_entry&.dig(:id)
  log_received_at = log_entry&.dig(:received_at)

  # Log webhook receipt (CloudWatch)
  log_webhook(source, headers, body)

  # Verify webhook signature
  unless WebhookVerifier.verify(source, body, headers)
    puts "ERROR: Invalid signature for #{source} webhook"

    # Update log status to failed
    if log_id && log_received_at
      @webhook_logger.update_status(
        id: log_id,
        received_at: log_received_at,
        status: "signature_failed",
        additional_data: { error_message: "Invalid signature" }
      )
    end

    return response(401, { error: "Invalid signature" })
  end

  puts "INFO: Signature verified for #{source} webhook"

  # Update log status to verified
  if log_id && log_received_at
    @webhook_logger.update_status(
      id: log_id,
      received_at: log_received_at,
      status: "verified"
    )
  end

  # Parse the webhook payload
  payload = JSON.parse(body) rescue {}

  # PCO webhooks: Log only, do not trigger workflow (collecting data to determine which events matter)
  # Cloudflare webhooks: Trigger workflow immediately
  if source == "pco"
    puts "INFO: PCO webhook logged (workflow trigger disabled - collecting event data)"

    # Update log status to logged_only
    if log_id && log_received_at
      @webhook_logger.update_status(
        id: log_id,
        received_at: log_received_at,
        status: "logged_only",
        additional_data: {
          workflow_triggered: false,
          reason: "PCO workflow trigger disabled - collecting event data"
        }
      )
    end

    return response(200, {
      received: true,
      source: source,
      workflow_triggered: false,
      reason: "PCO webhooks are being logged only (sync runs on schedule)",
      log_id: log_id
    })
  end

  # Trigger GitHub Actions sync workflow (Cloudflare only for now)
  result = GithubTrigger.dispatch_sync_workflow(triggered_by: source)

  if result[:success]
    puts "INFO: Successfully triggered sync workflow"

    # Update log status to processed
    if log_id && log_received_at
      @webhook_logger.update_status(
        id: log_id,
        received_at: log_received_at,
        status: "processed",
        additional_data: {
          workflow_triggered: true,
          workflow_run_id: result[:run_id]
        }
      )
    end

    response(200, {
      received: true,
      source: source,
      workflow_triggered: true,
      log_id: log_id
    })
  else
    puts "ERROR: Failed to trigger workflow: #{result[:error]}"

    # Update log status to failed
    if log_id && log_received_at
      @webhook_logger.update_status(
        id: log_id,
        received_at: log_received_at,
        status: "workflow_failed",
        additional_data: {
          workflow_triggered: false,
          error_message: result[:error]
        }
      )
    end

    response(500, {
      received: true,
      source: source,
      workflow_triggered: false,
      error: result[:error],
      log_id: log_id
    })
  end
rescue JSON::ParserError => e
  puts "ERROR: Invalid JSON body: #{e.message}"
  response(400, { error: "Invalid JSON body" })
rescue => e
  puts "ERROR: Unexpected error: #{e.message}"
  puts e.backtrace.first(5).join("\n")
  response(500, { error: "Internal server error" })
end

# Health check handler
def health(event:, context:)
  response(200, {
    status: "healthy",
    stage: ENV["STAGE"] || "unknown",
    timestamp: Time.now.utc.iso8601
  })
end

private

# Build API Gateway response
def response(status_code, body)
  {
    statusCode: status_code,
    headers: {
      "Content-Type" => "application/json",
      "X-Request-Id" => SecureRandom.uuid
    },
    body: JSON.generate(body)
  }
end

# Normalize header keys to lowercase for consistent access
def normalize_headers(headers)
  headers.transform_keys(&:downcase)
end

# Log webhook for debugging (visible in CloudWatch)
def log_webhook(source, headers, body)
  puts "INFO: Received #{source} webhook"
  puts "DEBUG: Headers: #{headers.keys.join(', ')}"

  # Log payload summary (not full body for privacy)
  begin
    payload = JSON.parse(body)
    puts "DEBUG: Payload keys: #{payload.keys.join(', ')}" if payload.is_a?(Hash)
  rescue
    puts "DEBUG: Non-JSON body (#{body.length} bytes)"
  end
end
