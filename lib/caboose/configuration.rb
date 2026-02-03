# frozen_string_literal: true

module Caboose
  class Configuration
    attr_accessor :enabled
    attr_accessor :retention_hours
    attr_accessor :max_spans
    attr_accessor :ignore_request
    attr_writer :database_path

    # Spans: detailed trace data stored in SQLite (default: development only)
    # Metrics: aggregated counters in memory, flushed periodically (default: production only)
    attr_accessor :spans_enabled
    attr_accessor :metrics_enabled
    attr_accessor :metrics_flush_interval # seconds between flushes (default: 60)

    # Default patterns to auto-subscribe to for custom instrumentation
    # Use "app." prefix in your ActiveSupport::Notifications.instrument calls
    DEFAULT_SUBSCRIBE_PATTERNS = %w[app.].freeze

    attr_accessor :subscribe_patterns

    def initialize
      @enabled = true
      @retention_hours = 24
      @max_spans = 10_000
      @database_path = nil
      @ignore_request = ->(request) { false }
      @subscribe_patterns = DEFAULT_SUBSCRIBE_PATTERNS.dup

      # Environment-based defaults:
      # - Development: spans ON (detailed debugging), metrics OFF
      # - Production: spans OFF (too expensive), metrics ON (lightweight aggregation)
      @spans_enabled = rails_development?
      @metrics_enabled = rails_production?
      @metrics_flush_interval = 60 # seconds
    end

    def database_path
      @database_path || default_database_path
    end

    private

    def rails_development?
      defined?(Rails) && Rails.env.development?
    rescue StandardError
      false # Default to false for safety - avoids enabling spans unexpectedly in production
    end

    def rails_production?
      defined?(Rails) && Rails.env.production?
    rescue StandardError
      false
    end

    def default_database_path
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.join("db", "caboose.sqlite3").to_s
      else
        "caboose.sqlite3"
      end
    end
  end
end
