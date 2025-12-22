# frozen_string_literal: true

module Caboose
  class Configuration
    attr_accessor :enabled
    attr_accessor :retention_hours
    attr_accessor :max_spans
    attr_writer :database_path

    def initialize
      @enabled = true
      @retention_hours = 24
      @max_spans = 1000
      @database_path = nil
    end

    def database_path
      @database_path || default_database_path
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
