# frozen_string_literal: true

require "securerandom"

module Caboose
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless Caboose.enabled?

      # Skip Caboose's own routes and mini-profiler
      if env["PATH_INFO"]&.start_with?("/caboose", "/mini-profiler")
        return @app.call(env)
      end

      case_uuid = SecureRandom.uuid
      started_at = Time.now
      # Capture original path before mounted Rack apps modify PATH_INFO
      original_path = env["PATH_INFO"]

      Collector.push(Collector.new(case_uuid, started_at))

      begin
        status, headers, body = @app.call(env)

        duration_ms = ((Time.now - started_at) * 1000).round(2)
        content = extract_request_content(env, original_path)

        save_case(
          uuid: case_uuid,
          type: "request",
          name: case_name(env, content),
          status: status.to_s,
          duration_ms: duration_ms,
          content: content,
          started_at: started_at
        )

        [status, headers, body]
      rescue => e
        duration_ms = ((Time.now - started_at) * 1000).round(2)
        content = extract_request_content(env, original_path).merge(
          error: e.class.name,
          error_message: e.message
        )

        save_case(
          uuid: case_uuid,
          type: "request",
          name: case_name(env, content),
          status: "500",
          duration_ms: duration_ms,
          content: content,
          started_at: started_at
        )

        raise
      ensure
        Collector.pop
        maybe_prune
      end
    end

    private

    def save_case(attributes)
      clues = Collector.current&.clues || []

      Caboose.storage.save_case(attributes)
      Caboose.storage.save_clues(clues)
    rescue => e
      # Don't let storage errors break the app
      warn "[Caboose] Error saving case: #{e.message}"
    end

    def extract_request_content(env, original_path)
      content = {
        method: env["REQUEST_METHOD"],
        path: original_path,
        query_string: env["QUERY_STRING"],
        content_type: env["CONTENT_TYPE"],
        params: extract_params(env)
      }

      # Extract controller and action if available
      if env["action_dispatch.request.parameters"]
        params = env["action_dispatch.request.parameters"]
        content[:controller] = params["controller"] if params["controller"]
        content[:action] = params["action"] if params["action"]
      end

      content
    end

    def extract_params(env)
      return {} unless env["action_dispatch.request.parameters"]

      # Filter sensitive params
      params = env["action_dispatch.request.parameters"].dup
      filter_sensitive_params(params)
    rescue
      {}
    end

    def filter_sensitive_params(params)
      sensitive_keys = %w[password password_confirmation token secret api_key]

      params.each do |key, value|
        if sensitive_keys.any? { |s| key.to_s.downcase.include?(s) }
          params[key] = "[FILTERED]"
        elsif value.is_a?(Hash)
          filter_sensitive_params(value)
        end
      end

      params
    end

    def case_name(env, content)
      if content[:controller] && content[:action]
        "#{content[:controller]}##{content[:action]}"
      else
        "#{content[:method]} #{content[:path]}"
      end
    end

    def maybe_prune
      # Prune every 100 cases
      return unless rand(100) == 0

      Caboose.storage.prune(
        retention_hours: Caboose.configuration.retention_hours,
        max_cases: Caboose.configuration.max_cases
      )
    rescue => e
      warn "[Caboose] Error pruning: #{e.message}"
    end
  end
end
