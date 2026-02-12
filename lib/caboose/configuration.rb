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

    # Metrics HTTP submission settings
    attr_accessor :url        # URL of the Caboose metrics service
    attr_accessor :key        # API key for authentication
    attr_accessor :metrics_timeout     # HTTP timeout in seconds (default: 5)
    attr_accessor :metrics_gzip        # Whether to gzip payloads (default: true)

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

      # Metrics HTTP submission defaults
      @url = ENV.fetch("CABOOSE_URL", credentials_url || "https://caboose.dev")
      @key = ENV["CABOOSE_KEY"]
      @metrics_timeout = 5
      @metrics_gzip = true
    end

    # Check if metrics can be submitted (endpoint and API key configured)
    def metrics_submission_configured?
      !@url.nil? && !@url.empty? &&
        !@key.nil? && !@key.empty?
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

    def credentials_url
      return nil unless defined?(Rails) && Rails.application&.credentials
      Rails.application.credentials.dig(:caboose, :url)
    rescue StandardError
      nil
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
