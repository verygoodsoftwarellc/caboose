# frozen_string_literal: true

require_relative "test_helper"
require "caboose/metric_storage"
require "caboose/metric_span_processor"

class MetricSpanProcessorTest < Minitest::Test
  def setup
    @storage = Caboose::MetricStorage.new
    @processor = Caboose::MetricSpanProcessor.new(storage: @storage)
  end

  def test_web_request_creates_metric
    span = MockSpan.new(
      kind: :server,
      parent_span_id: nil,
      attributes: {
        "http.status_code" => 200,
        "code.namespace" => "UsersController",
        "code.function" => "show"
      },
      start_ns: 0,
      end_ns: 100_000_000 # 100ms
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "web", key.namespace
    assert_equal "rails", key.service
    assert_equal "UsersController", key.target
    assert_equal "show", key.operation
  end

  def test_web_request_error_tracking
    span = MockSpan.new(
      kind: :server,
      parent_span_id: nil,
      attributes: { "http.status_code" => 500 },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    result = @storage.drain
    counter = result.values.first
    assert_equal 1, counter[:error_count]
  end

  def test_background_job_creates_metric
    span = MockSpan.new(
      kind: :consumer,
      parent_span_id: nil,
      name: "MyJob process",
      attributes: {
        "code.namespace" => "MyJob",
        "code.function" => "perform",
        "messaging.system" => "sidekiq"
      },
      start_ns: 0,
      end_ns: 50_000_000 # 50ms
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "background", key.namespace
    assert_equal "sidekiq", key.service
    assert_equal "MyJob", key.target
    assert_equal "perform", key.operation
  end

  def test_database_span_creates_metric
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "db.system" => "postgresql",
        "db.name" => "myapp_production",
        "db.sql.table" => "users",
        "db.operation" => "SELECT"
      },
      start_ns: 0,
      end_ns: 5_000_000 # 5ms
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "db", key.namespace
    assert_equal "postgresql", key.service
    assert_equal "users", key.target
    assert_equal "SELECT", key.operation
  end

  def test_redis_span_creates_metric
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "db.system" => "redis",
        "db.redis.database_index" => "0",
        "db.operation" => "GET"
      },
      start_ns: 0,
      end_ns: 1_000_000 # 1ms
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "db", key.namespace
    assert_equal "redis", key.service
    assert_equal "0", key.target
    assert_equal "get", key.operation
  end

  def test_http_client_span_creates_metric
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "POST",
        "http.host" => "api.stripe.com",
        "http.target" => "/v1/charges",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 200_000_000 # 200ms
    )

    @processor.on_end(span)

    assert_equal 1, @storage.size
    key = @storage.drain.keys.first
    assert_equal "http", key.namespace
    assert_equal "api.stripe.com", key.service
    assert_equal "/v1/charges", key.target
    assert_equal "POST", key.operation
  end

  def test_duration_calculation
    span = MockSpan.new(
      kind: :server,
      parent_span_id: nil,
      attributes: { "http.status_code" => 200 },
      start_ns: 1_000_000_000, # 1 second mark
      end_ns: 1_150_000_000 # 1.15 second mark = 150ms duration
    )

    @processor.on_end(span)

    result = @storage.drain
    counter = result.values.first
    assert_equal 150, counter[:sum_ms]
  end

  def test_ignores_child_server_spans
    # A server span with a parent is not a root request
    span = MockSpan.new(
      kind: :server,
      parent_span_id: "abc123def456",
      attributes: { "http.status_code" => 200 },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    assert @storage.empty?
  end

  def test_ignores_spans_without_timestamps
    span = MockSpan.new(
      kind: :server,
      parent_span_id: nil,
      attributes: {},
      start_ns: nil,
      end_ns: nil
    )

    @processor.on_end(span)

    assert @storage.empty?
  end

  def test_force_flush_returns_success
    result = @processor.force_flush
    assert_equal OpenTelemetry::SDK::Trace::Export::SUCCESS, result
  end

  def test_shutdown_returns_success
    result = @processor.shutdown
    assert_equal OpenTelemetry::SDK::Trace::Export::SUCCESS, result
  end

  def test_http_path_normalizes_numeric_ids
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "api.example.com",
        "http.target" => "/users/12345/posts/67890",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "/users/:id/posts/:id", key.target
  end

  def test_http_path_normalizes_uuids
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "api.example.com",
        "http.target" => "/items/550e8400-e29b-41d4-a716-446655440000",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "/items/:uuid", key.target
  end

  def test_http_path_normalizes_mongo_ids
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "api.example.com",
        "http.target" => "/documents/507f1f77bcf86cd799439011",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "/documents/:id", key.target
  end

  def test_http_path_normalizes_long_tokens
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "api.example.com",
        "http.target" => "/verify/a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "/verify/:token", key.target
  end

  def test_http_path_preserves_static_segments
    span = MockSpan.new(
      kind: :client,
      parent_span_id: "abc123",
      attributes: {
        "http.method" => "GET",
        "http.host" => "api.example.com",
        "http.target" => "/api/v1/users/search",
        "http.status_code" => 200
      },
      start_ns: 0,
      end_ns: 100_000_000
    )

    @processor.on_end(span)

    key = @storage.drain.keys.first
    assert_equal "/api/v1/users/search", key.target
  end

  # Mock span class for testing
  class MockSpan
    attr_reader :kind, :parent_span_id, :name, :attributes, :start_timestamp, :end_timestamp, :status

    def initialize(kind:, parent_span_id:, attributes: {}, start_ns: 0, end_ns: 100_000_000, name: "test_span", status: nil)
      @kind = kind
      @parent_span_id = parent_span_id
      @name = name
      @attributes = attributes
      @start_timestamp = start_ns
      @end_timestamp = end_ns
      @status = status
    end
  end
end
