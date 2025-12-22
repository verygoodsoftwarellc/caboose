# frozen_string_literal: true

require "test_helper"

class CollectorTest < Minitest::Test
  def setup
    Caboose::Collector.clear
  end

  def teardown
    Caboose::Collector.clear
  end

  def test_current_returns_nil_by_default
    assert_nil Caboose::Collector.current
  end

  def test_push_sets_current_collector
    started_at = Time.now
    collector = Caboose::Collector.new("uuid-123", started_at)

    Caboose::Collector.push(collector)

    assert_equal collector, Caboose::Collector.current
  end

  def test_clear_removes_current
    collector = Caboose::Collector.new("uuid-123", Time.now)
    Caboose::Collector.push(collector)

    Caboose::Collector.clear

    assert_nil Caboose::Collector.current
  end

  def test_record_adds_clue
    started_at = Time.now
    collector = Caboose::Collector.new("uuid-123", started_at)

    clue_started_at = started_at + 0.1
    collector.record(
      "sql.active_record",
      started_at: clue_started_at,
      duration_ms: 5.2,
      content: { sql: "SELECT * FROM users" }
    )

    clues = collector.clues
    assert_equal 1, clues.size

    clue = clues.first
    assert_equal "uuid-123", clue[:case_uuid]
    assert_equal "sql.active_record", clue[:type]
    assert_equal 5.2, clue[:duration_ms]
    assert_equal({ sql: "SELECT * FROM users" }, clue[:content])
    assert_in_delta 100, clue[:started_at_offset_ms], 1
  end

  def test_clues_returns_copy
    collector = Caboose::Collector.new("uuid-123", Time.now)

    clues1 = collector.clues
    clues2 = collector.clues

    refute_same clues1, clues2
  end
end
