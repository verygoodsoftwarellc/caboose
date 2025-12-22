# frozen_string_literal: true

require "test_helper"

class TestCaboose < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Caboose::VERSION
  end

  def test_configuration_defaults
    config = Caboose::Configuration.new

    assert_equal true, config.enabled
    assert_equal 24, config.retention_hours
    assert_equal 1000, config.max_cases
    assert_includes config.ignore, "request.action_dispatch"
  end

  def test_configure_block
    Caboose.configure do |config|
      config.enabled = false
      config.retention_hours = 12
    end

    refute Caboose.enabled?
    assert_equal 12, Caboose.configuration.retention_hours
  ensure
    # Reset for other tests
    Caboose.instance_variable_set(:@configuration, nil)
  end

  def test_ignored_notifications
    config = Caboose::Configuration.new
    config.ignore = %w[foo.bar]

    assert config.ignored?("foo.bar")
    refute config.ignored?("baz.qux")
  end
end
