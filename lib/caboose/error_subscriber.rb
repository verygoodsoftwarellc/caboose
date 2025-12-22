# frozen_string_literal: true

module Caboose
  # Subscriber for Rails.error that records exceptions as clues
  # Works with Rails 7.0+ error reporting API
  class ErrorSubscriber
    class << self
      def subscribe!
        return if @subscribed
        return unless defined?(Rails) && Rails.respond_to?(:error)

        Rails.error.subscribe(new)
        @subscribed = true
      end

      def subscribed?
        @subscribed == true
      end
    end

    # Called by Rails.error when an error is reported
    # @param error [Exception] the error that was reported
    # @param handled [Boolean] whether the error was handled or will be re-raised
    # @param severity [Symbol] :error, :warning, or :info
    # @param context [Hash] additional context provided when reporting
    # @param source [String] where the error originated (default: "application")
    def report(error, handled:, severity:, context:, source: nil)
      return unless Caboose.enabled?
      return unless Collector.current

      Collector.current.record(
        "exception",
        started_at: Time.now,
        duration_ms: 0,
        content: {
          "class" => error.class.name,
          "message" => error.message.to_s.truncate(1000),
          "backtrace" => filtered_backtrace(error),
          "handled" => handled,
          "severity" => severity.to_s,
          "source" => source || "application",
          "context" => sanitize_context(context)
        }
      )
    end

    private

    def filtered_backtrace(error)
      return [] unless error.backtrace

      # Get first 20 lines, filter out gem paths for cleaner display
      error.backtrace.first(20).map do |line|
        # Keep app lines as-is, truncate gem paths
        if line.include?("/app/") || line.include?("/lib/")
          line
        else
          line.sub(%r{.*/gems/}, "")
        end
      end
    end

    def sanitize_context(context)
      return {} if context.blank?

      context.transform_values do |value|
        case value
        when String, Numeric, TrueClass, FalseClass, NilClass
          value
        when Symbol
          value.to_s
        else
          value.to_s.truncate(500)
        end
      end
    end
  end
end
