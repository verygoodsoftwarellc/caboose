# frozen_string_literal: true

require "sqlite3"
require "json"

module Caboose
  class SQLiteExporter
    SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
    FAILURE = OpenTelemetry::SDK::Trace::Export::FAILURE
    TIMEOUT = OpenTelemetry::SDK::Trace::Export::TIMEOUT

    def initialize(database_path)
      @database_path = database_path
      @mutex = Mutex.new
      setup_database
    end

    def export(span_datas, timeout: nil)
      @mutex.synchronize do
        span_datas.each do |span_data|
          next if should_ignore_span?(span_data)

          create_span(span_data)
        end
      end

      SUCCESS
    rescue => e
      warn "[Caboose] SQLite export error: #{e.message}"
      FAILURE
    end

    def force_flush(timeout: nil)
      SUCCESS
    end

    def shutdown(timeout: nil)
      SUCCESS
    end

    private

    def should_ignore_span?(span_data)
      span_data.name&.start_with?("Caboose::")
    end

    def create_span(span_data)
      now = Time.now.iso8601(6)

      sql = <<~SQL
        INSERT INTO caboose_spans (name, kind, span_id, trace_id, parent_span_id, start_timestamp, end_timestamp, total_recorded_links, total_recorded_events, total_recorded_properties, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL

      values = [
        span_data.name,
        span_data.kind.to_s,
        span_data.hex_span_id,
        span_data.hex_trace_id,
        span_data.hex_parent_span_id,
        span_data.start_timestamp,
        span_data.end_timestamp,
        span_data.total_recorded_links,
        span_data.total_recorded_events,
        span_data.total_recorded_attributes,
        now,
        now
      ]

      connection.execute(sql, values)
      span_record_id = connection.last_insert_row_id

      span_data.events&.each do |span_event|
        create_event(span_record_id, span_event)
      end

      create_properties("Caboose::Span", span_record_id, span_data.attributes)
    end

    def create_event(span_record_id, span_event)
      now = Time.now.iso8601(6)
      timestamp = span_event.timestamp ? Time.at(span_event.timestamp / 1_000_000_000.0).iso8601(6) : now

      sql = <<~SQL
        INSERT INTO caboose_events (span_id, name, created_at, updated_at)
        VALUES (?, ?, ?, ?)
      SQL

      connection.execute(sql, [span_record_id, span_event.name, timestamp, now])
      event_record_id = connection.last_insert_row_id
      create_properties("Caboose::Event", event_record_id, span_event.attributes)
    end

    def create_properties(owner_type, owner_id, attributes)
      return unless attributes

      now = Time.now.iso8601(6)

      sql = <<~SQL
        INSERT INTO caboose_properties (key, value, value_type, owner_type, owner_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      SQL

      attributes.each do |key, value|
        next if value.nil?

        value_type = determine_value_type(value)
        serialized_value = JSON.generate(value)
        connection.execute(sql, [key, serialized_value, value_type, owner_type, owner_id, now, now])
      end
    end

    def determine_value_type(value)
      case value
      when String then 0  # string
      when Integer then 1 # integer
      when Float then 2   # float
      when TrueClass, FalseClass then 3 # boolean
      when Array then 4   # array
      else 0              # default to string
      end
    end

    def setup_database
      @mutex.synchronize do
        db = connection
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA synchronous=NORMAL")

        db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS caboose_spans (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            span_id TEXT NOT NULL,
            trace_id TEXT NOT NULL,
            parent_span_id TEXT,
            start_timestamp INTEGER NOT NULL,
            end_timestamp INTEGER NOT NULL,
            total_recorded_properties INTEGER NOT NULL DEFAULT 0,
            total_recorded_events INTEGER NOT NULL DEFAULT 0,
            total_recorded_links INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        SQL

        db.execute(<<~SQL)
          CREATE INDEX IF NOT EXISTS idx_spans_span_id ON caboose_spans(span_id)
        SQL

        db.execute(<<~SQL)
          CREATE INDEX IF NOT EXISTS idx_spans_trace_id ON caboose_spans(trace_id)
        SQL

        db.execute(<<~SQL)
          CREATE INDEX IF NOT EXISTS idx_spans_parent_span_id ON caboose_spans(parent_span_id)
        SQL

        db.execute(<<~SQL)
          CREATE INDEX IF NOT EXISTS idx_spans_created_at ON caboose_spans(created_at)
        SQL

        db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS caboose_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            span_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY (span_id) REFERENCES caboose_spans(id)
          )
        SQL

        db.execute(<<~SQL)
          CREATE INDEX IF NOT EXISTS idx_events_span_id ON caboose_events(span_id)
        SQL

        db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS caboose_properties (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            key TEXT NOT NULL,
            value TEXT,
            value_type INTEGER NOT NULL DEFAULT 0,
            owner_type TEXT NOT NULL,
            owner_id INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        SQL

        db.execute(<<~SQL)
          CREATE INDEX IF NOT EXISTS idx_properties_owner ON caboose_properties(owner_type, owner_id)
        SQL

        db.execute(<<~SQL)
          CREATE INDEX IF NOT EXISTS idx_properties_key ON caboose_properties(key)
        SQL
      end
    end

    def connection
      key = :"caboose_sqlite_db_#{@database_path.hash}"
      Thread.current[key] ||= begin
        dir = File.dirname(@database_path)
        FileUtils.mkdir_p(dir) unless File.directory?(dir)
        ::SQLite3::Database.new(@database_path, results_as_hash: true)
      end
    end
  end
end
