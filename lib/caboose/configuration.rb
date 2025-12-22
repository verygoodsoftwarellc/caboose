# frozen_string_literal: true

module Caboose
  class Configuration
    DEFAULT_IGNORES = %w[
      start_processing.action_controller
      process_middleware.action_dispatch
      request.action_dispatch
    ]

    attr_accessor :enabled
    attr_accessor :ignore
    attr_accessor :retention_hours
    attr_accessor :max_cases
    attr_writer :database_path

    def initialize
      @enabled = true
      @ignore = DEFAULT_IGNORES.dup
      @retention_hours = 24
      @max_cases = 1000
      @database_path = nil
    end

    def database_path
      @database_path || default_database_path
    end

    def ignored?(name)
      @ignore.include?(name)
    end

    private

    def default_database_path
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.join("db", "caboose.sqlite3").to_s
      else
        "caboose.sqlite3"
      end
    end
  end
end
