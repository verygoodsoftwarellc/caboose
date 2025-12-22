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
        untraced_requests: ->(env) {
          request = Rack::Request.new(env)
          return true if request.path.start_with?("/caboose")

          configuration.ignore_request.call(request)
        }
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

  # Payload transformers for different notification types
  NOTIFICATION_TRANSFORMERS = {
    "sql.active_record" => ->(payload) {
      attrs = {}
      attrs["db.statement"] = payload[:sql] if payload[:sql]
      attrs["name"] = payload[:name] if payload[:name]
      attrs["db.name"] = payload[:connection]&.pool&.db_config&.name rescue nil
      attrs
    },
    "instantiation.active_record" => ->(payload) {
      attrs = {}
      attrs["record_count"] = payload[:record_count] if payload[:record_count]
      attrs["class_name"] = payload[:class_name] if payload[:class_name]
      attrs
    },
    "cache_read.active_support" => ->(payload) {
      store = payload[:store]
      store_name = store.is_a?(String) ? store : store&.class&.name
      { "key" => payload[:key]&.to_s, "hit" => payload[:hit], "store" => store_name }
    },
    "cache_write.active_support" => ->(payload) {
      store = payload[:store]
      store_name = store.is_a?(String) ? store : store&.class&.name
      { "key" => payload[:key]&.to_s, "store" => store_name }
    },
    "cache_delete.active_support" => ->(payload) {
      store = payload[:store]
      store_name = store.is_a?(String) ? store : store&.class&.name
      { "key" => payload[:key]&.to_s, "store" => store_name }
    },
    "cache_exist?.active_support" => ->(payload) {
      store = payload[:store]
      store_name = store.is_a?(String) ? store : store&.class&.name
      { "key" => payload[:key]&.to_s, "exist" => payload[:exist], "store" => store_name }
    },
    "cache_fetch_hit.active_support" => ->(payload) {
      store = payload[:store]
      store_name = store.is_a?(String) ? store : store&.class&.name
      { "key" => payload[:key]&.to_s, "store" => store_name }
    },
    "deliver.action_mailer" => ->(payload) {
      attrs = {}
      attrs["mailer"] = payload[:mailer] if payload[:mailer]
      attrs["message_id"] = payload[:message_id] if payload[:message_id]
      attrs["to"] = Array(payload[:to]).join(", ") if payload[:to]
      attrs["subject"] = payload[:subject] if payload[:subject]
      attrs
    },
    "process.action_mailer" => ->(payload) {
      attrs = {}
      attrs["mailer"] = payload[:mailer] if payload[:mailer]
      attrs["action"] = payload[:action] if payload[:action]
      attrs
    }
  }.freeze

  def subscribe_to_notifications
    NOTIFICATION_TRANSFORMERS.each do |pattern, transformer|
      OpenTelemetry::Instrumentation::ActiveSupport.subscribe(tracer, pattern, transformer)
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
