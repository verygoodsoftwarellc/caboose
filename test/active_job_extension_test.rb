# frozen_string_literal: true

require "test_helper"
require "active_record"
require "active_job"
require "global_id"

# Set up in-memory SQLite database
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

# Create a simple model
ActiveRecord::Schema.define do
  create_table :widgets, force: true do |t|
    t.string :name
    t.boolean :production, default: false
    t.timestamps
  end
end

class Widget < ActiveRecord::Base
  include GlobalID::Identification

  def production?
    production
  end
end

# Configure GlobalID
GlobalID.app = "test"
GlobalID::Locator.use :test do |gid|
  gid.model_class.find(gid.model_id)
end

# Set up ActiveJob
ActiveJob::Base.queue_adapter = :inline

# Include Caboose extension
class ApplicationJob < ActiveJob::Base
  include Caboose::ActiveJobExtension
end

# Test job that uses the widget
class WidgetJob < ApplicationJob
  # Track what was received so we can verify
  cattr_accessor :received_widget
  cattr_accessor :widget_was_ar_model
  cattr_accessor :production_check_result

  def perform(widget)
    self.class.received_widget = widget
    self.class.widget_was_ar_model = widget.is_a?(Widget)
    self.class.production_check_result = widget.production?
  end
end

class ActiveJobExtensionTest < Minitest::Test
  def setup
    # Reset tracking
    WidgetJob.received_widget = nil
    WidgetJob.widget_was_ar_model = nil
    WidgetJob.production_check_result = nil

    # Clear thread-local connection so each test gets a fresh database
    Thread.current[:caboose_db] = nil

    # Set up Caboose
    Caboose.configure do |config|
      config.enabled = true
      config.database_path = ":memory:"
    end
    Caboose.reset_storage!
  end

  def test_job_receives_active_record_model_not_string
    widget = Widget.create!(name: "Test Widget", production: true)

    # Perform the job
    WidgetJob.perform_now(widget)

    # Verify the job received an actual Widget, not a string
    assert WidgetJob.widget_was_ar_model, "Job should receive a Widget instance, not #{WidgetJob.received_widget.class}"
    assert_equal widget.id, WidgetJob.received_widget.id
    assert_equal true, WidgetJob.production_check_result
  end

  def test_job_can_call_methods_on_active_record_model
    widget = Widget.create!(name: "Production Widget", production: true)

    # This should not raise an error
    WidgetJob.perform_now(widget)

    # Verify production? was callable
    assert_equal true, WidgetJob.production_check_result
  end

  def test_job_with_non_production_widget
    widget = Widget.create!(name: "Dev Widget", production: false)

    WidgetJob.perform_now(widget)

    assert_equal false, WidgetJob.production_check_result
  end

  def test_job_is_tracked_by_caboose
    widget = Widget.create!(name: "Tracked Widget", production: true)

    WidgetJob.perform_now(widget)

    # Check that Caboose recorded the job
    cases = Caboose.storage.list_cases(type: "job")
    assert_equal 1, cases.size
    assert_equal "WidgetJob", cases.first[:name]
    assert_equal "completed", cases.first[:status]
  end
end
