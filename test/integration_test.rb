# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "fileutils"

# Integration tests for the storage + controller logic
# Tests the data flow without needing a full Rails app
class IntegrationTest < Minitest::Test
  def setup
    # Clear thread-local connection so each test gets a fresh database
    Thread.current[:caboose_db] = nil

    @tmpdir = Dir.mktmpdir
    @db_path = File.join(@tmpdir, "test.sqlite3")

    Caboose.configure do |config|
      config.database_path = @db_path
    end
    Caboose.reset_storage!

    seed_test_data
  end

  def teardown
    Thread.current[:caboose_db] = nil
    FileUtils.rm_rf(@tmpdir)
    Caboose.instance_variable_set(:@configuration, nil)
    Caboose.reset_storage!
  end

  def test_full_workflow_cases_list
    storage = Caboose.storage
    cases = storage.list_cases

    assert_equal 3, cases.size

    # Most recent first
    assert_equal "case-3", cases[0][:uuid]
    assert_equal "job", cases[0][:type]
    assert_equal "MyJob", cases[0][:name]

    assert_equal "case-2", cases[1][:uuid]
    assert_equal "request", cases[1][:type]

    assert_equal "case-1", cases[2][:uuid]
    assert_equal "request", cases[2][:type]
  end

  def test_full_workflow_filter_by_type
    storage = Caboose.storage

    requests = storage.list_cases(type: "request")
    assert_equal 2, requests.size
    assert requests.all? { |c| c[:type] == "request" }

    jobs = storage.list_cases(type: "job")
    assert_equal 1, jobs.size
    assert_equal "job", jobs[0][:type]
  end

  def test_full_workflow_case_with_clues
    storage = Caboose.storage

    kase = storage.find_case("case-1")
    assert_equal "GET /users", kase[:name]
    assert_equal "200", kase[:status]
    assert_equal 45.2, kase[:duration_ms]

    clues = storage.clues_for_case("case-1")
    assert_equal 2, clues.size

    sql_clue = clues.find { |c| c[:type] == "sql.active_record" }
    assert_equal 5, sql_clue[:started_at_offset_ms]
    assert_equal 12, sql_clue[:duration_ms]
    assert_equal "SELECT * FROM users", sql_clue[:content]["sql"]

    cache_clue = clues.find { |c| c[:type] == "cache_read.active_support" }
    assert_equal 20, cache_clue[:started_at_offset_ms]
    assert_equal "users:all", cache_clue[:content]["key"]
  end

  def test_full_workflow_clue_count_in_list
    storage = Caboose.storage
    cases = storage.list_cases

    case_with_clues = cases.find { |c| c[:uuid] == "case-1" }
    assert_equal 2, case_with_clues[:clue_count]

    case_without_clues = cases.find { |c| c[:uuid] == "case-2" }
    assert_equal 0, case_without_clues[:clue_count]
  end

  def test_full_workflow_filter_by_name
    storage = Caboose.storage

    results = storage.list_cases(name: "users")
    assert_equal 2, results.size
    assert results.all? { |c| c[:name].include?("users") }
  end

  def test_full_workflow_case_not_found
    storage = Caboose.storage

    kase = storage.find_case("nonexistent-uuid")
    assert_nil kase
  end

  def test_collector_records_clues_correctly
    started_at = Time.now
    collector = Caboose::Collector.new("test-uuid", started_at)

    # Simulate some events
    collector.record("sql.active_record", started_at: started_at + 0.01, duration_ms: 5, content: { sql: "SELECT 1" })
    collector.record("cache_read.active_support", started_at: started_at + 0.02, duration_ms: 1, content: { key: "foo" })
    collector.record("render_template.action_view", started_at: started_at + 0.03, duration_ms: 10, content: { template: "index" })

    clues = collector.clues
    assert_equal 3, clues.size

    # Check offsets are calculated correctly
    assert_in_delta 10, clues[0][:started_at_offset_ms], 1
    assert_in_delta 20, clues[1][:started_at_offset_ms], 1
    assert_in_delta 30, clues[2][:started_at_offset_ms], 1
  end

  private

  def seed_test_data
    storage = Caboose.storage
    now = Time.now

    # Case with clues
    storage.save_case(
      uuid: "case-1",
      type: "request",
      name: "GET /users",
      status: "200",
      duration_ms: 45.2,
      content: { method: "GET", path: "/users" },
      started_at: now
    )
    storage.save_clues([
      { case_uuid: "case-1", type: "sql.active_record", started_at_offset_ms: 5, duration_ms: 12, content: { sql: "SELECT * FROM users" } },
      { case_uuid: "case-1", type: "cache_read.active_support", started_at_offset_ms: 20, duration_ms: 1, content: { key: "users:all" } }
    ])

    # Another request
    storage.save_case(
      uuid: "case-2",
      type: "request",
      name: "POST /users",
      status: "201",
      duration_ms: 120.5,
      content: { method: "POST", path: "/users" },
      started_at: now + 1
    )

    # A job
    storage.save_case(
      uuid: "case-3",
      type: "job",
      name: "MyJob",
      status: "completed",
      duration_ms: 500,
      content: { job_id: "abc123", queue_name: "default" },
      started_at: now + 2
    )
  end
end
