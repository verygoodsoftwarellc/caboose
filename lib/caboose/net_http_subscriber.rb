# frozen_string_literal: true

require "net/http"

module Caboose
  # Instruments Net::HTTP requests to record them as clues
  # - Rails 7.1+ uses built-in ActiveSupport::Notifications
  # - Rails 7.0 uses monkey-patching
  class NetHttpSubscriber
    class << self
      def subscribe!
        return if @subscribed

        if rails_71_or_newer?
          subscribe_via_notifications!
        else
          subscribe_via_patch!
        end

        @subscribed = true
      end

      def subscribed?
        @subscribed == true
      end

      private

      def rails_71_or_newer?
        Rails::VERSION::MAJOR > 7 ||
          (Rails::VERSION::MAJOR == 7 && Rails::VERSION::MINOR >= 1)
      end

      def subscribe_via_notifications!
        ActiveSupport::Notifications.subscribe("request.net_http") do |name, start, finish, id, payload|
          next unless Caboose.enabled?
          next unless Collector.current

          duration_ms = ((finish - start) * 1000).round(2)

          Collector.current.record(
            "http.request",
            started_at: start,
            duration_ms: duration_ms,
            content: {
              "method" => payload[:method],
              "url" => build_url(payload),
              "host" => payload[:uri]&.host,
              "path" => payload[:uri]&.path,
              "status" => payload[:code],
              "content_length" => payload[:response]&.content_length
            }
          )
        end
      end

      def subscribe_via_patch!
        # Monkey-patch for Rails 7.0
        Net::HTTP.prepend(NetHttpInstrumentation)
      end

      def build_url(payload)
        uri = payload[:uri]
        return nil unless uri

        "#{uri.scheme}://#{uri.host}#{uri.path}#{uri.query ? "?#{uri.query}" : ""}"
      end
    end

    # Module to prepend to Net::HTTP for Rails 7.0
    module NetHttpInstrumentation
      def request(req, body = nil, &block)
        return super unless Caboose.enabled?
        return super unless Caboose::Collector.current

        start_time = Time.now
        response = super
        finish_time = Time.now

        duration_ms = ((finish_time - start_time) * 1000).round(2)

        uri = build_request_uri(req)

        Caboose::Collector.current.record(
          "http.request",
          started_at: start_time,
          duration_ms: duration_ms,
          content: {
            "method" => req.method,
            "url" => uri,
            "host" => address,
            "path" => req.path,
            "status" => response.code.to_i,
            "content_length" => response.content_length
          }
        )

        response
      rescue => e
        # Still record failed requests
        finish_time = Time.now
        duration_ms = ((finish_time - start_time) * 1000).round(2)

        Caboose::Collector.current&.record(
          "http.request",
          started_at: start_time,
          duration_ms: duration_ms,
          content: {
            "method" => req.method,
            "url" => build_request_uri(req),
            "host" => address,
            "path" => req.path,
            "error" => e.class.name,
            "error_message" => e.message
          }
        )

        raise
      end

      private

      def build_request_uri(req)
        scheme = use_ssl? ? "https" : "http"
        host_with_port = port == (use_ssl? ? 443 : 80) ? address : "#{address}:#{port}"
        "#{scheme}://#{host_with_port}#{req.path}"
      end
    end
  end
end
