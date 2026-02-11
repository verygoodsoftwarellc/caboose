# frozen_string_literal: true

require "net/http"
require "json"
require "zlib"
require "stringio"
require "securerandom"
require "socket"

module Caboose
  # Submits metrics to the Caboose metrics service via HTTP.
  # Handles gzip compression, retries with exponential backoff, and error handling.
  class MetricSubmitter
    SCHEMA_VERSION = "V1"
    GZIP_ENCODING = "gzip"
    USER_AGENT = "Caboose Ruby/#{Caboose::VERSION}"

    # Default timeouts (in seconds)
    DEFAULT_OPEN_TIMEOUT = 2
    DEFAULT_READ_TIMEOUT = 5
    DEFAULT_WRITE_TIMEOUT = 5

    # Max retries before giving up
    MAX_RETRIES = 3

    class SubmissionError < StandardError
      attr_reader :request_id, :response_code, :response_body

      def initialize(message, request_id:, response_code: nil, response_body: nil)
        @request_id = request_id
        @response_code = response_code
        @response_body = response_body
        super(message)
      end
    end

    attr_reader :endpoint, :api_key, :backoff_policy

    def initialize(endpoint:, api_key:, backoff_policy: nil, open_timeout: nil, read_timeout: nil, write_timeout: nil)
      @endpoint = URI(endpoint)
      @api_key = api_key
      @backoff_policy = backoff_policy || BackoffPolicy.new
      @open_timeout = open_timeout || DEFAULT_OPEN_TIMEOUT
      @read_timeout = read_timeout || DEFAULT_READ_TIMEOUT
      @write_timeout = write_timeout || DEFAULT_WRITE_TIMEOUT
    end

    # Submit drained metrics to the server.
    # Returns [success_count, error] where error may be nil on success.
    def submit(drained)
      return [0, nil] if drained.empty?

      request_id = SecureRandom.uuid
      body = build_body(drained, request_id)
      return [0, nil] if body.nil?

      @backoff_policy.reset
      response, error = retry_with_backoff(MAX_RETRIES) { post(body, request_id) }

      if error
        [0, error]
      else
        [drained.size, nil]
      end
    end

    private

    def build_body(drained, request_id)
      metrics = drained.map do |key, values|
        {
          bucket: format_time(key.bucket),
          namespace: key.namespace,
          service: key.service,
          target: key.target || "",
          operation: key.operation,
          count: values[:count],
          sum_ms: values[:sum_ms],
          error_count: values[:error_count]
        }
      end

      payload = {
        request_id: request_id,
        schema_version: SCHEMA_VERSION,
        metrics: metrics
      }

      gzip(JSON.generate(payload))
    rescue => e
      warn "[Caboose] Failed to build submission body: #{e.message}"
      nil
    end

    def post(body, request_id)
      http = Net::HTTP.new(@endpoint.host, @endpoint.port)
      http.use_ssl = @endpoint.scheme == "https"
      if http.use_ssl? && local_endpoint?
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @write_timeout if http.respond_to?(:write_timeout=)

      request_uri = @endpoint.request_uri
      request = Net::HTTP::Post.new(request_uri == "" ? "/" : request_uri)
      request["Content-Type"] = "application/json"
      request["Content-Encoding"] = GZIP_ENCODING
      request["Authorization"] = "Bearer #{@api_key}"
      request["User-Agent"] = USER_AGENT
      request["X-Request-Id"] = request_id
      request["X-Schema-Version"] = SCHEMA_VERSION

      # Client metadata headers (like Flipper)
      request["X-Client-Language"] = "ruby"
      request["X-Client-Language-Version"] = RUBY_VERSION
      request["X-Client-Platform"] = RUBY_PLATFORM
      request["X-Client-Pid"] = Process.pid.to_s
      request["X-Client-Hostname"] = Socket.gethostname rescue "unknown"

      request.body = body
      response = http.request(request)

      code = response.code.to_i

      # Success
      if code >= 200 && code < 300
        return [response, false] # [result, should_retry]
      end

      # Retriable errors: rate limiting, server errors
      if code == 429 || code >= 500
        raise SubmissionError.new(
          "Retriable error: #{code}",
          request_id: request_id,
          response_code: code,
          response_body: response.body
        )
      end

      # Non-retriable client errors (4xx except 429)
      [response, false]
    end

    def retry_with_backoff(max_attempts)
      attempts_remaining = max_attempts
      last_error = nil

      while attempts_remaining > 0
        begin
          result, should_retry = yield
          return [result, nil] unless should_retry
        rescue SubmissionError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET => e
          last_error = e
          attempts_remaining -= 1

          if attempts_remaining > 0
            sleep_time = @backoff_policy.next_interval / 1000.0
            sleep(sleep_time)
          end
          next
        rescue => e
          # Unexpected errors - don't retry
          return [nil, e]
        end
      end

      [nil, last_error]
    end

    def gzip(string)
      io = StringIO.new
      io.set_encoding("BINARY")
      gz = Zlib::GzipWriter.new(io)
      gz.write(string)
      gz.close
      io.string
    end

    def format_time(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def local_endpoint?
      host = @endpoint.host
      host == "localhost" || host == "127.0.0.1" || host == "::1"
    end
  end
end
