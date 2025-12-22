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
    assert_equal 500, config.max_spans
  end
end
