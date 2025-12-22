# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "fileutils"

class StorageTest < Minitest::Test
  def setup
    Thread.current[:caboose_db] = nil
    Caboose.reset_storage!
    @tmpdir = Dir.mktmpdir
    @db_path = File.join(@tmpdir, "test.sqlite3")
    @storage = Caboose::Storage::SQLite.new(@db_path)
  end

  def teardown
    # Clear thread-local connection
    Thread.current[:caboose_db] = nil
    FileUtils.rm_rf(@tmpdir)
  end

  def test_save_and_find_case
    started_at = Time.now
    @storage.save_case(
      uuid: "case-123",
      type: "request",
      name: "GET /users",
      status: "200",
      duration_ms: 45.2,
      content: { method: "GET", path: "/users" },
      started_at: started_at
    )

    found = @storage.find_case("case-123")

    assert_equal "case-123", found[:uuid]
    assert_equal "request", found[:type]
    assert_equal "GET /users", found[:name]
    assert_equal "200", found[:status]
    assert_equal 45.2, found[:duration_ms]
    assert_equal({ "method" => "GET", "path" => "/users" }, found[:content])
  end

  def test_find_case_returns_nil_for_missing
    assert_nil @storage.find_case("nonexistent")
  end

  def test_save_and_list_cases
    now = Time.now
    @storage.save_case(uuid: "case-1", type: "request", name: "GET /", status: "200", duration_ms: 10, content: {}, started_at: now)
    @storage.save_case(uuid: "case-2", type: "job", name: "MyJob", status: "completed", duration_ms: 100, content: {}, started_at: now + 1)
    @storage.save_case(uuid: "case-3", type: "request", name: "POST /users", status: "201", duration_ms: 50, content: {}, started_at: now + 2)

    cases = @storage.list_cases

    assert_equal 3, cases.size
    assert_equal "case-3", cases[0][:uuid] # Most recent first
    assert_equal "case-2", cases[1][:uuid]
    assert_equal "case-1", cases[2][:uuid]
  end

  def test_list_cases_filters_by_type
    now = Time.now
    @storage.save_case(uuid: "case-1", type: "request", name: "GET /", status: "200", duration_ms: 10, content: {}, started_at: now)
    @storage.save_case(uuid: "case-2", type: "job", name: "MyJob", status: "completed", duration_ms: 100, content: {}, started_at: now)

    requests = @storage.list_cases(type: "request")
    jobs = @storage.list_cases(type: "job")

    assert_equal 1, requests.size
    assert_equal "case-1", requests[0][:uuid]
    assert_equal 1, jobs.size
    assert_equal "case-2", jobs[0][:uuid]
  end

  def test_save_and_retrieve_clues
    now = Time.now
    @storage.save_case(uuid: "case-1", type: "request", name: "GET /", status: "200", duration_ms: 100, content: {}, started_at: now)

    @storage.save_clues([
      { case_uuid: "case-1", type: "sql.active_record", started_at_offset_ms: 10, duration_ms: 5, content: { sql: "SELECT 1" } },
      { case_uuid: "case-1", type: "cache_read.active_support", started_at_offset_ms: 20, duration_ms: 1, content: { key: "foo" } }
    ])

    clues = @storage.clues_for_case("case-1")

    assert_equal 2, clues.size
    assert_equal "sql.active_record", clues[0][:type]
    assert_equal 10, clues[0][:started_at_offset_ms]
    assert_equal({ "sql" => "SELECT 1" }, clues[0][:content])
    assert_equal "cache_read.active_support", clues[1][:type]
  end

  def test_count_cases
    assert_equal 0, @storage.count_cases

    now = Time.now
    @storage.save_case(uuid: "case-1", type: "request", name: "GET /", status: "200", duration_ms: 10, content: {}, started_at: now)
    @storage.save_case(uuid: "case-2", type: "request", name: "GET /", status: "200", duration_ms: 10, content: {}, started_at: now)

    assert_equal 2, @storage.count_cases
  end

  def test_list_cases_includes_clue_count
    now = Time.now
    @storage.save_case(uuid: "case-1", type: "request", name: "GET /", status: "200", duration_ms: 100, content: {}, started_at: now)
    @storage.save_clues([
      { case_uuid: "case-1", type: "sql.active_record", started_at_offset_ms: 10, duration_ms: 5, content: {} },
      { case_uuid: "case-1", type: "sql.active_record", started_at_offset_ms: 20, duration_ms: 5, content: {} }
    ])

    cases = @storage.list_cases

    assert_equal 2, cases[0][:clue_count]
  end
end
