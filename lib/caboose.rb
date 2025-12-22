# frozen_string_literal: true

require_relative "caboose/version"
require_relative "caboose/configuration"

require "opentelemetry/sdk"

require_relative "caboose/sqlite_exporter"

module Caboose
  class Error < StandardError; end

  MISSING_PARENT_ID = "0000000000000000"

  module_function

  def configuration
    @configuration ||= Configuration.new
  end

  def configure
    yield(configuration) if block_given?
  end

  def enabled?
    configuration.enabled
  end

  def exporter
    @exporter ||= SQLiteExporter.new(configuration.database_path)
  end

  def exporter=(exporter)
    @exporter = exporter
  end

  def span_processor
    @span_processor ||= OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      exporter,
      max_queue_size: 1000,
      max_export_batch_size: 100,
      schedule_delay: 1000 # 1 second
    )
  end

  def span_processor=(span_processor)
    @span_processor = span_processor
  end

  def tracer
    @tracer ||= OpenTelemetry.tracer_provider.tracer("Caboose", Caboose::VERSION)
  end

  def untraced(&block)
    OpenTelemetry::Common::Utilities.untraced(&block)
  end

  # Configure OpenTelemetry with selected instrumentations
  def configure_opentelemetry
    return if @otel_configured

    service_name = if defined?(Rails) && Rails.application
      Rails.application.class.module_parent_name.underscore rescue "rails_app"
    else
      "app"
    end

    # Require only the instrumentations we want
    require "opentelemetry-instrumentation-rack"
    require "opentelemetry-instrumentation-net_http"
    require "opentelemetry-instrumentation-active_support"
    require "opentelemetry-instrumentation-action_pack" if defined?(ActionController)
    require "opentelemetry-instrumentation-action_view" if defined?(ActionView)
    require "opentelemetry-instrumentation-active_job" if defined?(ActiveJob)

    OpenTelemetry::SDK.configure do |c|
      c.service_name = service_name
      c.add_span_processor(span_processor)

      # Configure specific instrumentations
      c.use "OpenTelemetry::Instrumentation::Rack",
        untraced_requests: ->(env) { env["PATH_INFO"]&.start_with?("/caboose") }
      c.use "OpenTelemetry::Instrumentation::Net::HTTP"
      c.use "OpenTelemetry::Instrumentation::ActiveSupport"
      c.use "OpenTelemetry::Instrumentation::ActionPack" if defined?(ActionController)
      c.use "OpenTelemetry::Instrumentation::ActionView" if defined?(ActionView)
      c.use "OpenTelemetry::Instrumentation::ActiveJob" if defined?(ActiveJob)
    end

    # Subscribe to common ActiveSupport notification patterns
    # This captures SQL, cache, mailer, and custom notifications
    subscribe_to_notifications

    @otel_configured = true
  end

  # Common notification patterns to subscribe to
  NOTIFICATION_PATTERNS = %w[
    sql.active_record
    instantiation.active_record
    cache_read.active_support
    cache_write.active_support
    cache_delete.active_support
    cache_exist?.active_support
    cache_fetch_hit.active_support
    deliver.action_mailer
    process.action_mailer
  ].freeze

  def subscribe_to_notifications
    NOTIFICATION_PATTERNS.each do |pattern|
      OpenTelemetry::Instrumentation::ActiveSupport.subscribe(tracer, pattern)
    rescue => e
      # Ignore errors for patterns that don't exist
    end
  end

  def storage
    @storage ||= Storage::SQLite.new(configuration.database_path)
  end

  def reset_storage!
    @storage = nil
  end

  def reset!
    @configuration = nil
    @exporter = nil
    @span_processor = nil
    @tracer = nil
    @storage = nil
    @otel_configured = false
  end
end

require_relative "caboose/storage"
require_relative "caboose/engine" if defined?(Rails)
