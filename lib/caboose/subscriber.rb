# frozen_string_literal: true

require "active_support/notifications"

module Caboose
  class Subscriber
    # Patterns to exclude from caller traces
    CALLER_EXCLUDE_PATTERNS = [
      /\/gems\//,                    # Gem code
      /\/ruby\//,                    # Ruby stdlib
      /\/rubygems\//,                # RubyGems
      /\/bundler\//,                 # Bundler
      /\/caboose\//i,               # Caboose itself
      /activerecord/i,               # ActiveRecord internals
      /activesupport/i,              # ActiveSupport internals
      /actionpack/i,                 # ActionPack internals
      /actionview/i,                 # ActionView internals
      /railties/i,                   # Railties
      /<internal:/,                  # Ruby internal frames
    ].freeze

    class << self
      def subscribe!
        return if @subscribed

        ActiveSupport::Notifications.subscribe(/.*/) do |name, start, finish, id, payload|
          next unless Caboose.enabled?
          next if name.start_with?("!")  # Skip internal Rails events
          next if Caboose.ignored?(name)
          next unless Collector.current

          # Skip Caboose's own requests
          next if name == "process_action.action_controller" &&
                  payload[:controller]&.start_with?("Caboose::")

          duration_ms = ((finish - start) * 1000).round(2)

          content = sanitize_payload(payload)

          # Capture caller for SQL queries to help identify N+1s
          if name == "sql.active_record"
            content["caller"] = extract_app_caller
          end

          Collector.current.record(
            name,
            started_at: start,
            duration_ms: duration_ms,
            content: content
          )
        end

        @subscribed = true
      end

      def subscribed?
        @subscribed == true
      end

      private

      # Extract the most relevant application caller lines for a SQL query
      # Returns up to 3 lines from app code, stripped of Rails.root prefix
      # Falls back to first meaningful non-internal frame if no app code found
      def extract_app_caller
        return nil unless defined?(Rails.root) && Rails.root

        root = Rails.root.to_s
        app_lines = []
        fallback_line = nil

        # Use caller_locations for better performance (lazy in Ruby 3.2+)
        # Skip first 5 frames which are Caboose/AS::Notifications internals
        caller_locations(5, 50).each do |location|
          path = location.path
          next if path.nil?
          next if path =~ /<internal:/ # Always skip Ruby internals

          # Check if this is app code (under Rails.root and not excluded)
          is_app_code = path.start_with?(root) &&
                        !CALLER_EXCLUDE_PATTERNS.any? { |pattern| path =~ pattern }

          if is_app_code
            relative_path = path.sub("#{root}/", "")
            label = location.label
            line_info = "#{relative_path}:#{location.lineno}"
            line_info += " in `#{label}`" if label && !label.empty?

            app_lines << line_info
            break if app_lines.size >= 3
          elsif fallback_line.nil? && path !~ /caboose/i
            # Capture first non-Caboose frame as fallback
            # Clean up gem paths for readability
            display_path = path.sub(%r{.*/gems/[^/]+/}, '')
            label = location.label
            fallback_line = "#{display_path}:#{location.lineno}"
            fallback_line += " in `#{label}`" if label && !label.empty?
          end
        end

        # Return app lines if found, otherwise fallback
        if app_lines.any?
          app_lines
        elsif fallback_line
          ["(from gem) #{fallback_line}"]
        else
          nil
        end
      end

      # Keys that contain objects we can't serialize meaningfully or are sensitive
      SKIP_KEYS = %w[
        binds
        connection
        password
        request
        secret_key_base
        secret_token
        type_casted_binds
        username
      ].freeze

      def sanitize_payload(payload)
        # Deep clone and convert to serializable format
        sanitize_value(payload)
      end

      def sanitize_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(k, v), hash|
            key = k.to_s
            next if SKIP_KEYS.include?(key)
            hash[key] = sanitize_value(v)
          end
        when Array
          value.map { |v| sanitize_value(v) }
        when String, Numeric, TrueClass, FalseClass, NilClass
          value
        when Time, DateTime
          value.iso8601(6)
        when Date
          value.iso8601
        when Symbol
          value.to_s
        else
          # For complex objects, try to get a string representation
          value.to_s
        end
      rescue => e
        "[Error serializing: #{e.message}]"
      end
    end
  end
end
