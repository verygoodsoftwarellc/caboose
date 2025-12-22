# frozen_string_literal: true

require "sqlite3"
require "json"

module Caboose
  module Storage
    class SQLite < Base
      MISSING_PARENT_ID = "0000000000000000"

      # Rails framework controller prefixes to filter (lowercase/underscored format)
      RAILS_CONTROLLER_PREFIXES = %w[
        active_storage/
        action_mailbox/
        rails/
        caboose/
      ].freeze

      def initialize(database_path)
        @database_path = database_path
        @mutex = Mutex.new
        setup_database
      end

      # List root spans that are HTTP requests (for the requests index)
      def list_requests(status: nil, method: nil, name: nil, origin: nil, limit: 50, offset: 0)
        # Find root spans with kind=server that have http.method property
        conditions = ["s.parent_span_id = ?", "s.kind = ?"]
        values = [MISSING_PARENT_ID, "server"]

        # Filter by http.method property existing (makes it an HTTP request)
        # We join with properties to filter

        if status
          case status
          when "2xx"
            conditions << "status_prop.value LIKE ?"
            values << "2%"
          when "3xx"
            conditions << "status_prop.value LIKE ?"
            values << "3%"
          when "4xx"
            conditions << "status_prop.value LIKE ?"
            values << "4%"
          when "5xx"
            conditions << "status_prop.value LIKE ?"
            values << "5%"
          else
            conditions << "status_prop.value = ?"
            values << status.to_s
          end
        end

        if method
          conditions << "method_prop.value = ?"
          values << "\"#{method}\""
        end

        if name
          conditions << "s.name LIKE ?"
          values << "%#{name}%"
        end

        if origin
          if origin == "rails"
            controller_conditions = RAILS_CONTROLLER_PREFIXES.map { "controller_prop.value LIKE ?" }
            conditions << "(#{controller_conditions.join(" OR ")})"
            RAILS_CONTROLLER_PREFIXES.each { |prefix| values << "%#{prefix}%" }
          elsif origin == "app"
            controller_conditions = RAILS_CONTROLLER_PREFIXES.map { "controller_prop.value LIKE ?" }
            conditions << "(controller_prop.value IS NULL OR NOT (#{controller_conditions.join(" OR ")}))"
            RAILS_CONTROLLER_PREFIXES.each { |prefix| values << "%#{prefix}%" }
          end
        end

        where_clause = "WHERE #{conditions.join(" AND ")}"
        values << limit
        values << offset

        rows = query_all(<<~SQL, values)
          SELECT s.*,
                 method_prop.value as http_method,
                 status_prop.value as http_status,
                 target_prop.value as http_target,
                 controller_prop.value as controller,
                 action_prop.value as action
          FROM caboose_spans s
          LEFT JOIN caboose_properties method_prop ON method_prop.owner_type = 'Caboose::Span' AND method_prop.owner_id = s.id AND method_prop.key = 'http.method'
          LEFT JOIN caboose_properties status_prop ON status_prop.owner_type = 'Caboose::Span' AND status_prop.owner_id = s.id AND status_prop.key = 'http.status_code'
          LEFT JOIN caboose_properties target_prop ON target_prop.owner_type = 'Caboose::Span' AND target_prop.owner_id = s.id AND target_prop.key = 'http.target'
          LEFT JOIN caboose_properties controller_prop ON controller_prop.owner_type = 'Caboose::Span' AND controller_prop.owner_id = s.id AND controller_prop.key = 'code.namespace'
          LEFT JOIN caboose_properties action_prop ON action_prop.owner_type = 'Caboose::Span' AND action_prop.owner_id = s.id AND action_prop.key = 'code.function'
          #{where_clause}
          AND method_prop.value IS NOT NULL
          ORDER BY s.created_at DESC
          LIMIT ? OFFSET ?
        SQL

        rows.map { |row| row_to_request(row) }
      end

      def count_requests(status: nil, method: nil, name: nil, origin: nil)
        conditions = ["s.parent_span_id = ?", "s.kind = ?"]
        values = [MISSING_PARENT_ID, "server"]

        if status
          case status
          when "2xx"
            conditions << "status_prop.value LIKE ?"
            values << "2%"
          when "3xx"
            conditions << "status_prop.value LIKE ?"
            values << "3%"
          when "4xx"
            conditions << "status_prop.value LIKE ?"
            values << "4%"
          when "5xx"
            conditions << "status_prop.value LIKE ?"
            values << "5%"
          else
            conditions << "status_prop.value = ?"
            values << status.to_s
          end
        end

        if method
          conditions << "method_prop.value = ?"
          values << "\"#{method}\""
        end

        if name
          conditions << "s.name LIKE ?"
          values << "%#{name}%"
        end

        if origin
          if origin == "rails"
            controller_conditions = RAILS_CONTROLLER_PREFIXES.map { "controller_prop.value LIKE ?" }
            conditions << "(#{controller_conditions.join(" OR ")})"
            RAILS_CONTROLLER_PREFIXES.each { |prefix| values << "%#{prefix}%" }
          elsif origin == "app"
            controller_conditions = RAILS_CONTROLLER_PREFIXES.map { "controller_prop.value LIKE ?" }
            conditions << "(controller_prop.value IS NULL OR NOT (#{controller_conditions.join(" OR ")}))"
            RAILS_CONTROLLER_PREFIXES.each { |prefix| values << "%#{prefix}%" }
          end
        end

        where_clause = "WHERE #{conditions.join(" AND ")}"

        row = query_one(<<~SQL, values)
          SELECT COUNT(*) as count
          FROM caboose_spans s
          LEFT JOIN caboose_properties method_prop ON method_prop.owner_type = 'Caboose::Span' AND method_prop.owner_id = s.id AND method_prop.key = 'http.method'
          LEFT JOIN caboose_properties status_prop ON status_prop.owner_type = 'Caboose::Span' AND status_prop.owner_id = s.id AND status_prop.key = 'http.status_code'
          LEFT JOIN caboose_properties controller_prop ON controller_prop.owner_type = 'Caboose::Span' AND controller_prop.owner_id = s.id AND controller_prop.key = 'code.namespace'
          #{where_clause}
          AND method_prop.value IS NOT NULL
        SQL

        row ? row["count"] : 0
      end

      # Find a request by trace_id (for the detail view)
      def find_request(trace_id)
        row = query_one(<<~SQL, [trace_id, MISSING_PARENT_ID])
          SELECT s.*
          FROM caboose_spans s
          WHERE s.trace_id = ? AND s.parent_span_id = ?
        SQL

        return nil unless row

        span = row_to_span(row)
        span[:properties] = load_properties("Caboose::Span", span[:id])
        span
      end

      # Get all spans for a trace (for the waterfall view)
      def spans_for_trace(trace_id)
        rows = query_all(<<~SQL, [trace_id])
          SELECT * FROM caboose_spans
          WHERE trace_id = ?
          ORDER BY start_timestamp ASC
        SQL

        spans = rows.map { |row| row_to_span(row) }

        # Load properties for all spans
        span_ids = spans.map { |s| s[:id] }
        if span_ids.any?
          all_properties = load_properties_for_ids("Caboose::Span", span_ids)
          spans.each do |span|
            span[:properties] = all_properties[span[:id]] || {}
          end
        end

        # Load events for all spans
        if span_ids.any?
          all_events = load_events_for_spans(span_ids)
          spans.each do |span|
            span[:events] = all_events[span[:id]] || []
          end
        end

        spans
      end

      # Load properties for a specific owner
      def load_properties(owner_type, owner_id)
        rows = query_all(<<~SQL, [owner_type, owner_id])
          SELECT key, value, value_type FROM caboose_properties
          WHERE owner_type = ? AND owner_id = ?
        SQL

        rows.each_with_object({}) do |row, hash|
          hash[row["key"]] = parse_property_value(row["value"], row["value_type"])
        end
      end

      # Load properties for multiple owners at once
      def load_properties_for_ids(owner_type, owner_ids)
        return {} if owner_ids.empty?

        placeholders = owner_ids.map { "?" }.join(", ")
        rows = query_all(<<~SQL, [owner_type] + owner_ids)
          SELECT owner_id, key, value, value_type FROM caboose_properties
          WHERE owner_type = ? AND owner_id IN (#{placeholders})
        SQL

        result = Hash.new { |h, k| h[k] = {} }
        rows.each do |row|
          result[row["owner_id"]][row["key"]] = parse_property_value(row["value"], row["value_type"])
        end
        result
      end

      # Load events for multiple spans at once
      def load_events_for_spans(span_ids)
        return {} if span_ids.empty?

        placeholders = span_ids.map { "?" }.join(", ")
        event_rows = query_all(<<~SQL, span_ids)
          SELECT * FROM caboose_events
          WHERE span_id IN (#{placeholders})
        SQL

        # Group events by span_id
        events_by_span = Hash.new { |h, k| h[k] = [] }
        event_ids = []

        event_rows.each do |row|
          event = {
            id: row["id"],
            span_id: row["span_id"],
            name: row["name"],
            created_at: row["created_at"]
          }
          events_by_span[row["span_id"]] << event
          event_ids << row["id"]
        end

        # Load properties for all events
        if event_ids.any?
          event_properties = load_properties_for_ids("Caboose::Event", event_ids)
          events_by_span.each do |_, events|
            events.each do |event|
              event[:properties] = event_properties[event[:id]] || {}
            end
          end
        end

        events_by_span
      end

      def prune(retention_hours:, max_spans:)
        cutoff = (Time.now - (retention_hours * 3600)).iso8601(6)

        # Delete old properties first (for old spans and events)
        execute(<<~SQL, [cutoff])
          DELETE FROM caboose_properties WHERE owner_type = 'Caboose::Span' AND owner_id IN (
            SELECT id FROM caboose_spans WHERE created_at < ?
          )
        SQL

        execute(<<~SQL, [cutoff])
          DELETE FROM caboose_properties WHERE owner_type = 'Caboose::Event' AND owner_id IN (
            SELECT id FROM caboose_events WHERE span_id IN (
              SELECT id FROM caboose_spans WHERE created_at < ?
            )
          )
        SQL

        # Delete old events
        execute(<<~SQL, [cutoff])
          DELETE FROM caboose_events WHERE span_id IN (
            SELECT id FROM caboose_spans WHERE created_at < ?
          )
        SQL

        # Delete old spans
        execute(<<~SQL, [cutoff])
          DELETE FROM caboose_spans WHERE created_at < ?
        SQL

        # Also prune if over max_spans (keep newest)
        execute(<<~SQL, [max_spans])
          DELETE FROM caboose_properties WHERE owner_type = 'Caboose::Span' AND owner_id IN (
            SELECT id FROM caboose_spans
            ORDER BY created_at DESC
            LIMIT -1 OFFSET ?
          )
        SQL

        execute(<<~SQL, [max_spans])
          DELETE FROM caboose_properties WHERE owner_type = 'Caboose::Event' AND owner_id IN (
            SELECT id FROM caboose_events WHERE span_id IN (
              SELECT id FROM caboose_spans
              ORDER BY created_at DESC
              LIMIT -1 OFFSET ?
            )
          )
        SQL

        execute(<<~SQL, [max_spans])
          DELETE FROM caboose_events WHERE span_id IN (
            SELECT id FROM caboose_spans
            ORDER BY created_at DESC
            LIMIT -1 OFFSET ?
          )
        SQL

        execute(<<~SQL, [max_spans])
          DELETE FROM caboose_spans WHERE id IN (
            SELECT id FROM caboose_spans
            ORDER BY created_at DESC
            LIMIT -1 OFFSET ?
          )
        SQL
      end

      def clear_all
        execute("DELETE FROM caboose_properties")
        execute("DELETE FROM caboose_events")
        execute("DELETE FROM caboose_spans")
      end

      private

      def setup_database
        # The SQLiteExporter creates the tables, but we ensure they exist here too
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

          db.execute("CREATE INDEX IF NOT EXISTS idx_spans_span_id ON caboose_spans(span_id)")
          db.execute("CREATE INDEX IF NOT EXISTS idx_spans_trace_id ON caboose_spans(trace_id)")
          db.execute("CREATE INDEX IF NOT EXISTS idx_spans_parent_span_id ON caboose_spans(parent_span_id)")
          db.execute("CREATE INDEX IF NOT EXISTS idx_spans_created_at ON caboose_spans(created_at)")

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

          db.execute("CREATE INDEX IF NOT EXISTS idx_events_span_id ON caboose_events(span_id)")

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

          db.execute("CREATE INDEX IF NOT EXISTS idx_properties_owner ON caboose_properties(owner_type, owner_id)")
          db.execute("CREATE INDEX IF NOT EXISTS idx_properties_key ON caboose_properties(key)")
        end
      end

      def connection
        Thread.current[:caboose_storage_db] ||= begin
          dir = File.dirname(@database_path)
          FileUtils.mkdir_p(dir) unless File.directory?(dir)
          ::SQLite3::Database.new(@database_path, results_as_hash: true)
        end
      end

      def execute(sql, values = [])
        @mutex.synchronize do
          connection.execute(sql, values)
        end
      end

      def query_one(sql, values = [])
        @mutex.synchronize do
          connection.execute(sql, values).first
        end
      end

      def query_all(sql, values = [])
        @mutex.synchronize do
          connection.execute(sql, values)
        end
      end

      def row_to_span(row)
        {
          id: row["id"],
          name: row["name"],
          kind: row["kind"],
          span_id: row["span_id"],
          trace_id: row["trace_id"],
          parent_span_id: row["parent_span_id"],
          start_timestamp: row["start_timestamp"],
          end_timestamp: row["end_timestamp"],
          duration_ms: (row["end_timestamp"] - row["start_timestamp"]) / 1_000_000.0,
          created_at: row["created_at"],
          properties: {},
          events: []
        }
      end

      def row_to_request(row)
        span = row_to_span(row)

        # Add convenience accessors from the joined properties
        span[:http_method] = parse_property_value(row["http_method"], 0)
        span[:http_status] = parse_property_value(row["http_status"], 1)
        span[:http_target] = parse_property_value(row["http_target"], 0)
        span[:controller] = parse_property_value(row["controller"], 0)
        span[:action] = parse_property_value(row["action"], 0)

        span
      end

      def parse_property_value(value, value_type)
        return nil if value.nil?

        JSON.parse(value)
      rescue JSON::ParserError
        value
      end
    end
  end
end
