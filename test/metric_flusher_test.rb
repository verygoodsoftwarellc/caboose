# frozen_string_literal: true

require_relative "test_helper"
require "caboose/metric_key"
require "caboose/metric_storage"
require "caboose/metric_flusher"

class MetricFlusherTest < Minitest::Test
  def setup
    @storage = Caboose::MetricStorage.new
    @store = MockMetricStore.new
    @flusher = Caboose::MetricFlusher.new(
      storage: @storage,
      store: @store,
      interval: 0.1 # 100ms for fast tests
    )
  end

  def teardown
    @flusher.stop if @flusher.running?
  end

  def test_default_interval
    flusher = Caboose::MetricFlusher.new(storage: @storage, store: @store)
    assert_equal 60, flusher.interval
  end

  def test_custom_interval
    assert_equal 0.1, @flusher.interval
  end

  def test_start_creates_thread
    refute @flusher.running?

    @flusher.start

    assert @flusher.running?
  end

  def test_start_is_idempotent
    @flusher.start
    @flusher.start
    @flusher.start

    assert @flusher.running?
  end

  def test_stop_stops_thread
    @flusher.start
    assert @flusher.running?

    @flusher.stop

    refute @flusher.running?
  end

  def test_stop_flushes_remaining_data
    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)

    @flusher.stop

    assert_equal 1, @store.flush_count
  end

  def test_flush_now_drains_storage
    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)

    count = @flusher.flush_now

    assert_equal 1, count
    assert @storage.empty?
  end

  def test_background_flush_occurs
    @flusher.start

    key = create_key("web", "rails", "UsersController", "show")
    @storage.increment(key, duration_ms: 100, error: false)

    # Wait for background flush to occur
    sleep 0.25

    assert @store.flush_count >= 1
  end

  def test_after_fork_restarts_thread
    @flusher.start
    original_running = @flusher.running?

    # Simulate fork by calling after_fork
    @flusher.after_fork

    assert original_running
    assert @flusher.running?
  end

  def test_flush_now_handles_nil_storage
    flusher = Caboose::MetricFlusher.new(storage: nil, store: @store, interval: 1)
    count = flusher.flush_now

    assert_equal 0, count
  end

  def test_flush_now_handles_nil_store
    flusher = Caboose::MetricFlusher.new(storage: @storage, store: nil, interval: 1)
    count = flusher.flush_now

    assert_equal 0, count
  end

  private

  def create_key(namespace, service, target, operation)
    Caboose::MetricKey.new(
      bucket: Time.now.utc,
      namespace: namespace,
      service: service,
      target: target,
      operation: operation
    )
  end

  # Mock store for testing
  class MockMetricStore
    attr_reader :flush_count, :flushed_data

    def initialize
      @flush_count = 0
      @flushed_data = []
    end

    def flush(storage)
      data = storage.drain
      @flushed_data << data
      @flush_count += 1
      data.size
    end
  end
end
