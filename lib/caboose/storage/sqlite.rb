# frozen_string_literal: true

require "sqlite3"
require "json"

module Caboose
  module Storage
    class SQLite < Base
      def initialize(database_path)
        @database_path = database_path
        @mutex = Mutex.new
        setup_database
      end

      def save_case(attributes)
        values = [
          attributes[:uuid],
          attributes[:type],
          attributes[:name],
          attributes[:status],
          attributes[:duration_ms],
          JSON.generate(attributes[:content] || {}),
          attributes[:started_at].iso8601(6),
          attributes[:parent_case_uuid],
          Time.now.iso8601(6)
        ]
        execute(<<~SQL, values)
          INSERT INTO caboose_cases (uuid, type, name, status, duration_ms, content, started_at, parent_case_uuid, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
      end

      def update_case(uuid, attributes)
        sets = []
        values = []

        if attributes.key?(:status)
          sets << "status = ?"
          values << attributes[:status]
        end

        if attributes.key?(:duration_ms)
          sets << "duration_ms = ?"
          values << attributes[:duration_ms]
        end

        return if sets.empty?

        values << uuid
        execute("UPDATE caboose_cases SET #{sets.join(", ")} WHERE uuid = ?", values)
      end

      def save_clues(clues)
        return if clues.empty?

        placeholders = clues.map { "(?, ?, ?, ?, ?, ?)" }.join(", ")
        values = clues.flat_map do |clue|
          [
            clue[:case_uuid],
            clue[:type],
            clue[:started_at_offset_ms],
            clue[:duration_ms],
            JSON.generate(clue[:content] || {}),
            Time.now.iso8601(6)
          ]
        end

        execute(<<~SQL, values)
          INSERT INTO caboose_clues (case_uuid, type, started_at_offset_ms, duration_ms, content, created_at)
          VALUES #{placeholders}
        SQL
      end

      def find_case(uuid)
        row = query_one("SELECT * FROM caboose_cases WHERE uuid = ?", [uuid])
        return nil unless row

        row_to_case(row)
      end

      # Rails framework controller prefixes to filter (lowercase/underscored format)
      RAILS_CONTROLLER_PREFIXES = %w[
        active_storage/
        action_mailbox/
        rails/
        caboose/
      ].freeze

      def list_cases(type: nil, status: nil, method: nil, name: nil, origin: nil, limit: 50, offset: 0)
        conditions = []
        values = []

        if type
          conditions << "type = ?"
          values << type
        end

        if status
          # Handle status ranges like "2xx", "3xx", etc.
          case status
          when "2xx"
            conditions << "status LIKE '2%'"
          when "3xx"
            conditions << "status LIKE '3%'"
          when "4xx"
            conditions << "status LIKE '4%'"
          when "5xx"
            conditions << "status LIKE '5%'"
          else
            conditions << "status = ?"
            values << status
          end
        end

        if method
          # Method is stored in the content JSON
          conditions << "json_extract(content, '$.method') = ?"
          values << method
        end

        if name
          conditions << "name LIKE ?"
          values << "%#{name}%"
        end

        if origin
          # Filter by controller origin (app vs rails framework)
          controller_conditions = RAILS_CONTROLLER_PREFIXES.map { "json_extract(content, '$.controller') LIKE ?" }
          if origin == "rails"
            conditions << "(#{controller_conditions.join(" OR ")})"
            RAILS_CONTROLLER_PREFIXES.each { |prefix| values << "#{prefix}%" }
          elsif origin == "app"
            # Include requests with no controller (mounted Rack apps) OR app controllers
            conditions << "(json_extract(content, '$.controller') IS NULL OR NOT (#{controller_conditions.join(" OR ")}))"
            RAILS_CONTROLLER_PREFIXES.each { |prefix| values << "#{prefix}%" }
          end
        end

        where_clause = conditions.any? ? "WHERE #{conditions.join(" AND ")}" : ""
        values << limit
        values << offset

        rows = query_all(<<~SQL, values)
          SELECT *, (SELECT COUNT(*) FROM caboose_clues WHERE case_uuid = caboose_cases.uuid) as clue_count
          FROM caboose_cases
          #{where_clause}
          ORDER BY started_at DESC
          LIMIT ? OFFSET ?
        SQL

        rows.map { |row| row_to_case(row) }
      end

      def clues_for_case(case_uuid)
        rows = query_all(<<~SQL, [case_uuid])
          SELECT * FROM caboose_clues
          WHERE case_uuid = ?
          ORDER BY started_at_offset_ms ASC
        SQL

        rows.map { |row| row_to_clue(row) }
      end

      def list_clues(type: nil, search: nil, limit: 50, offset: 0)
        conditions = []
        values = []

        if type
          type_pattern = case type
          when "sql" then "%sql%"
          when "cache" then "%cache%"
          when "view" then "%render%"
          when "mail" then "%mail%"
          else "%#{type}%"
          end
          conditions << "caboose_clues.type LIKE ?"
          values << type_pattern
        end

        if search
          conditions << "caboose_clues.content LIKE ?"
          values << "%#{search}%"
        end

        where_clause = conditions.any? ? "WHERE #{conditions.join(" AND ")}" : ""
        values << limit
        values << offset

        rows = query_all(<<~SQL, values)
          SELECT caboose_clues.*,
            caboose_cases.name as case_name,
            caboose_cases.type as case_type,
            caboose_cases.started_at as case_started_at
          FROM caboose_clues
          JOIN caboose_cases ON caboose_cases.uuid = caboose_clues.case_uuid
          #{where_clause}
          ORDER BY caboose_cases.started_at DESC, caboose_clues.started_at_offset_ms ASC
          LIMIT ? OFFSET ?
        SQL

        rows.map { |row| row_to_clue_with_case(row) }
      end

      def find_clue(id)
        row = query_one(<<~SQL, [id])
          SELECT caboose_clues.*,
            caboose_cases.name as case_name,
            caboose_cases.type as case_type,
            caboose_cases.started_at as case_started_at
          FROM caboose_clues
          JOIN caboose_cases ON caboose_cases.uuid = caboose_clues.case_uuid
          WHERE caboose_clues.id = ?
        SQL

        return nil unless row
        row_to_clue_with_case(row)
      end

      def prune(retention_hours:, max_cases:)
        cutoff = (Time.now - (retention_hours * 3600)).iso8601(6)

        execute(<<~SQL, [cutoff])
          DELETE FROM caboose_clues WHERE case_uuid IN (
            SELECT uuid FROM caboose_cases WHERE created_at < ?
          )
        SQL

        execute(<<~SQL, [cutoff])
          DELETE FROM caboose_cases WHERE created_at < ?
        SQL

        # Also prune if over max_cases
        execute(<<~SQL, [max_cases])
          DELETE FROM caboose_clues WHERE case_uuid IN (
            SELECT uuid FROM caboose_cases
            ORDER BY created_at DESC
            LIMIT -1 OFFSET ?
          )
        SQL

        execute(<<~SQL, [max_cases])
          DELETE FROM caboose_cases WHERE uuid IN (
            SELECT uuid FROM caboose_cases
            ORDER BY created_at DESC
            LIMIT -1 OFFSET ?
          )
        SQL
      end

      def clear_all
        execute("DELETE FROM caboose_clues")
        execute("DELETE FROM caboose_cases")
      end

      def count_cases(type: nil, status: nil, method: nil, name: nil, origin: nil)
        conditions = []
        values = []

        if type
          conditions << "type = ?"
          values << type
        end

        if status
          case status
          when "2xx"
            conditions << "status LIKE '2%'"
          when "3xx"
            conditions << "status LIKE '3%'"
          when "4xx"
            conditions << "status LIKE '4%'"
          when "5xx"
            conditions << "status LIKE '5%'"
          else
            conditions << "status = ?"
            values << status
          end
        end

        if method
          conditions << "json_extract(content, '$.method') = ?"
          values << method
        end

        if name
          conditions << "name LIKE ?"
          values << "%#{name}%"
        end

        if origin
          controller_conditions = RAILS_CONTROLLER_PREFIXES.map { "json_extract(content, '$.controller') LIKE ?" }
          if origin == "rails"
            conditions << "(#{controller_conditions.join(" OR ")})"
            RAILS_CONTROLLER_PREFIXES.each { |prefix| values << "#{prefix}%" }
          elsif origin == "app"
            # Include requests with no controller (mounted Rack apps) OR app controllers
            conditions << "(json_extract(content, '$.controller') IS NULL OR NOT (#{controller_conditions.join(" OR ")}))"
            RAILS_CONTROLLER_PREFIXES.each { |prefix| values << "#{prefix}%" }
          end
        end

        where_clause = conditions.any? ? "WHERE #{conditions.join(" AND ")}" : ""
        row = query_one("SELECT COUNT(*) as count FROM caboose_cases #{where_clause}", values)
        row ? row["count"] : 0
      end

      def count_clues(type: nil, search: nil)
        conditions = []
        values = []

        if type
          type_pattern = case type
          when "sql" then "%sql%"
          when "cache" then "%cache%"
          when "view" then "%render%"
          when "mail" then "%mail%"
          else "%#{type}%"
          end
          conditions << "type LIKE ?"
          values << type_pattern
        end

        if search
          conditions << "content LIKE ?"
          values << "%#{search}%"
        end

        where_clause = conditions.any? ? "WHERE #{conditions.join(" AND ")}" : ""
        row = query_one("SELECT COUNT(*) as count FROM caboose_clues #{where_clause}", values)
        row ? row["count"] : 0
      end

      private

      def setup_database
        @mutex.synchronize do
          db = connection
          db.execute("PRAGMA journal_mode=WAL")
          db.execute("PRAGMA synchronous=NORMAL")

          db.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS caboose_cases (
              uuid TEXT PRIMARY KEY,
              type TEXT NOT NULL,
              name TEXT,
              status TEXT,
              duration_ms REAL,
              content TEXT,
              started_at TEXT NOT NULL,
              parent_case_uuid TEXT,
              created_at TEXT NOT NULL
            )
          SQL

          # Migration: Add parent_case_uuid if it doesn't exist
          columns = db.execute("PRAGMA table_info(caboose_cases)").map { |row| row["name"] }
          unless columns.include?("parent_case_uuid")
            db.execute("ALTER TABLE caboose_cases ADD COLUMN parent_case_uuid TEXT")
          end

          db.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS caboose_clues (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              case_uuid TEXT NOT NULL,
              type TEXT NOT NULL,
              started_at_offset_ms REAL,
              duration_ms REAL,
              content TEXT,
              created_at TEXT NOT NULL,
              FOREIGN KEY (case_uuid) REFERENCES caboose_cases(uuid)
            )
          SQL

          db.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_clues_case_uuid ON caboose_clues(case_uuid)
          SQL

          db.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_cases_created_at ON caboose_cases(created_at)
          SQL

          db.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_cases_type ON caboose_cases(type)
          SQL
        end
      end

      def connection
        Thread.current[:caboose_db] ||= begin
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

      def row_to_case(row)
        {
          uuid: row["uuid"],
          type: row["type"],
          name: row["name"],
          status: row["status"],
          duration_ms: row["duration_ms"],
          content: row["content"] ? JSON.parse(row["content"]) : {},
          started_at: Time.parse(row["started_at"]),
          created_at: Time.parse(row["created_at"]),
          parent_case_uuid: row["parent_case_uuid"],
          clue_count: row["clue_count"]
        }
      end

      def row_to_clue(row)
        {
          id: row["id"],
          case_uuid: row["case_uuid"],
          type: row["type"],
          started_at_offset_ms: row["started_at_offset_ms"],
          duration_ms: row["duration_ms"],
          content: row["content"] ? JSON.parse(row["content"]) : {},
          created_at: Time.parse(row["created_at"])
        }
      end

      def row_to_clue_with_case(row)
        row_to_clue(row).merge(
          case_name: row["case_name"],
          case_type: row["case_type"],
          case_started_at: row["case_started_at"] ? Time.parse(row["case_started_at"]) : nil
        )
      end
    end
  end
end
