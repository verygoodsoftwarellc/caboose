# frozen_string_literal: true

require_relative "test_helper"
require "caboose/metric_rollup"

class MetricRollupTest < Minitest::Test
  def test_default_retention_periods
    rollup = Caboose::MetricRollup.new

    # Default: 2 hours, 7 days, 90 days (in seconds)
    assert_equal 7200, rollup.minutes_retention      # 2 * 3600
    assert_equal 604800, rollup.hours_retention      # 7 * 86400
    assert_equal 7776000, rollup.days_retention      # 90 * 86400
  end

  def test_custom_retention_periods
    rollup = Caboose::MetricRollup.new(
      minutes_retention: 3600,    # 1 hour
      hours_retention: 259200,    # 3 days
      days_retention: 2592000     # 30 days
    )

    assert_equal 3600, rollup.minutes_retention
    assert_equal 259200, rollup.hours_retention
    assert_equal 2592000, rollup.days_retention
  end

  def test_class_run_method_creates_instance_and_calls_run
    # This is a smoke test that the class method exists and accepts options
    assert_respond_to Caboose::MetricRollup, :run!
  end

  def test_run_returns_result_hash_structure
    # Create a mock rollup that returns 0 for everything to test structure
    rollup = MockRollup.new

    result = rollup.run!

    assert_kind_of Hash, result
    assert_includes result.keys, :hours_created
    assert_includes result.keys, :days_created
    assert_includes result.keys, :minutes_deleted
    assert_includes result.keys, :hours_deleted
    assert_includes result.keys, :days_deleted
  end

  # Mock rollup for testing structure without DB
  class MockRollup < Caboose::MetricRollup
    def rollup_minutes_to_hours
      0
    end

    def rollup_hours_to_days
      0
    end

    def prune_minutes
      0
    end

    def prune_hours
      0
    end

    def prune_days
      0
    end
  end
end
