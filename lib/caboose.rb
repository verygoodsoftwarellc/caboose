# frozen_string_literal: true

require_relative "caboose/version"
require_relative "caboose/configuration"
require_relative "caboose/collector"
require_relative "caboose/storage"
require_relative "caboose/subscriber"
require_relative "caboose/middleware"
require_relative "caboose/active_job_extension"
require_relative "caboose/resque_plugin"
require_relative "caboose/error_subscriber"
require_relative "caboose/net_http_subscriber"

module Caboose
  class Error < StandardError; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def enabled?
      configuration.enabled
    end

    def ignored?(name)
      configuration.ignored?(name)
    end

    def storage
      @storage ||= Storage::SQLite.new(configuration.database_path)
    end

    def reset_storage!
      @storage = nil
    end

    def current_collector
      Collector.current
    end
  end
end

require_relative "caboose/engine" if defined?(Rails)
