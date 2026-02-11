# frozen_string_literal: true

module Caboose
  # Rolls up metrics from finer-grained to coarser-grained time buckets.
  # Minutes -> Hours -> Days
  #
  # Usage:
  #   # Roll up all eligible metrics
  #   Caboose::MetricRollup.run!
  #
  #   # Roll up with custom retention (in seconds, or use ActiveSupport durations)
  #   Caboose::MetricRollup.run!(
  #     minutes_retention: 2.hours,    # or 7200
  #     hours_retention: 7.days,       # or 604800
  #     days_retention: 90.days        # or 7776000
  #   )
  class MetricRollup
    # Default retention periods (in seconds)
    # 2 hours = 7200, 7 days = 604800, 90 days = 7776000
    DEFAULT_MINUTES_RETENTION = 7200
    DEFAULT_HOURS_RETENTION = 604800
    DEFAULT_DAYS_RETENTION = 7776000

    attr_reader :minutes_retention, :hours_retention, :days_retention

    def initialize(minutes_retention: DEFAULT_MINUTES_RETENTION,
                   hours_retention: DEFAULT_HOURS_RETENTION,
                   days_retention: DEFAULT_DAYS_RETENTION)
      @minutes_retention = minutes_retention
      @hours_retention = hours_retention
      @days_retention = days_retention
    end

    def self.run!(**options)
      new(**options).run!
    end

    def run!
      results = {
        hours_created: 0,
        days_created: 0,
        minutes_deleted: 0,
        hours_deleted: 0,
        days_deleted: 0
      }

      # Roll up minutes to hours (for data older than 1 hour to ensure completeness)
      results[:hours_created] = rollup_minutes_to_hours

      # Roll up hours to days (for data older than 1 day to ensure completeness)
      results[:days_created] = rollup_hours_to_days

      # Prune old data based on retention settings
      results[:minutes_deleted] = prune_minutes
      results[:hours_deleted] = prune_hours
      results[:days_deleted] = prune_days

      results
    end

    private

    def rollup_minutes_to_hours
      # Only roll up complete hours (data older than 1 hour ago)
      cutoff = beginning_of_hour(Time.current - 3600)

      # Find minute buckets that need to be rolled up
      minute_data = Metric
        .where("bucket < ?", cutoff)
        .group(:namespace, :service, :target, :operation)
        .group(hour_bucket_expression)
        .select(
          hour_bucket_expression + " as hour_bucket",
          :namespace,
          :service,
          :target,
          :operation,
          "SUM(count) as total_count",
          "SUM(sum_ms) as total_sum_ms",
          "SUM(error_count) as total_error_count"
        )

      count = 0
      now = Time.current

      minute_data.each do |row|
        upsert_hour(row, now)
        count += 1
      end

      count
    end

    def rollup_hours_to_days
      # Only roll up complete days (data older than 1 day ago)
      cutoff = beginning_of_day(Time.current - 86400)

      # Find hourly buckets that need to be rolled up
      hour_data = MetricHour
        .where("bucket < ?", cutoff)
        .group(:namespace, :service, :target, :operation)
        .group(day_bucket_expression)
        .select(
          day_bucket_expression + " as day_bucket",
          :namespace,
          :service,
          :target,
          :operation,
          "SUM(count) as total_count",
          "SUM(sum_ms) as total_sum_ms",
          "SUM(error_count) as total_error_count"
        )

      count = 0
      now = Time.current

      hour_data.each do |row|
        upsert_day(row, now)
        count += 1
      end

      count
    end

    def prune_minutes
      cutoff = Time.current - retention_to_seconds(minutes_retention)
      Metric.where("bucket < ?", cutoff).delete_all
    end

    def prune_hours
      cutoff = Time.current - retention_to_seconds(hours_retention)
      MetricHour.where("bucket < ?", cutoff).delete_all
    end

    def prune_days
      cutoff = Time.current - retention_to_seconds(days_retention)
      MetricDay.where("bucket < ?", cutoff).delete_all
    end

    # Convert retention value to seconds (supports both Integer and ActiveSupport::Duration)
    def retention_to_seconds(value)
      value.respond_to?(:to_i) ? value.to_i : value
    end

    # Round time down to beginning of hour
    def beginning_of_hour(time)
      Time.new(time.year, time.month, time.day, time.hour, 0, 0, time.utc_offset)
    end

    # Round time down to beginning of day
    def beginning_of_day(time)
      Time.new(time.year, time.month, time.day, 0, 0, 0, time.utc_offset)
    end

    def upsert_hour(row, now)
      adapter = MetricHour.connection.adapter_name.downcase

      case adapter
      when /postgresql/
        postgresql_upsert_hour(row, now)
      when /mysql/
        mysql_upsert_hour(row, now)
      when /sqlite/
        sqlite_upsert_hour(row, now)
      else
        fallback_upsert_hour(row, now)
      end
    end

    def upsert_day(row, now)
      adapter = MetricDay.connection.adapter_name.downcase

      case adapter
      when /postgresql/
        postgresql_upsert_day(row, now)
      when /mysql/
        mysql_upsert_day(row, now)
      when /sqlite/
        sqlite_upsert_day(row, now)
      else
        fallback_upsert_day(row, now)
      end
    end

    # Hour bucket expression varies by database
    def hour_bucket_expression
      adapter = Metric.connection.adapter_name.downcase

      case adapter
      when /postgresql/
        "date_trunc('hour', bucket)"
      when /mysql/
        "DATE_FORMAT(bucket, '%Y-%m-%d %H:00:00')"
      when /sqlite/
        "strftime('%Y-%m-%d %H:00:00', bucket)"
      else
        "date_trunc('hour', bucket)"
      end
    end

    # Day bucket expression varies by database
    def day_bucket_expression
      adapter = MetricHour.connection.adapter_name.downcase

      case adapter
      when /postgresql/
        "date_trunc('day', bucket)::date"
      when /mysql/
        "DATE(bucket)"
      when /sqlite/
        "date(bucket)"
      else
        "date_trunc('day', bucket)::date"
      end
    end

    # PostgreSQL upserts
    def postgresql_upsert_hour(row, now)
      MetricHour.connection.execute(<<~SQL)
        INSERT INTO caboose_metrics_hours (bucket, namespace, service, target, operation, count, sum_ms, error_count, created_at, updated_at)
        VALUES (
          #{MetricHour.connection.quote(row.hour_bucket)},
          #{MetricHour.connection.quote(row.namespace)},
          #{MetricHour.connection.quote(row.service)},
          #{MetricHour.connection.quote(row.target)},
          #{MetricHour.connection.quote(row.operation)},
          #{row.total_count.to_i},
          #{row.total_sum_ms.to_i},
          #{row.total_error_count.to_i},
          #{MetricHour.connection.quote(now)},
          #{MetricHour.connection.quote(now)}
        )
        ON CONFLICT (bucket, namespace, service, target, operation)
        DO UPDATE SET
          count = caboose_metrics_hours.count + EXCLUDED.count,
          sum_ms = caboose_metrics_hours.sum_ms + EXCLUDED.sum_ms,
          error_count = caboose_metrics_hours.error_count + EXCLUDED.error_count,
          updated_at = EXCLUDED.updated_at
      SQL
    end

    def postgresql_upsert_day(row, now)
      MetricDay.connection.execute(<<~SQL)
        INSERT INTO caboose_metrics_days (bucket, namespace, service, target, operation, count, sum_ms, error_count, created_at, updated_at)
        VALUES (
          #{MetricDay.connection.quote(row.day_bucket)},
          #{MetricDay.connection.quote(row.namespace)},
          #{MetricDay.connection.quote(row.service)},
          #{MetricDay.connection.quote(row.target)},
          #{MetricDay.connection.quote(row.operation)},
          #{row.total_count.to_i},
          #{row.total_sum_ms.to_i},
          #{row.total_error_count.to_i},
          #{MetricDay.connection.quote(now)},
          #{MetricDay.connection.quote(now)}
        )
        ON CONFLICT (bucket, namespace, service, target, operation)
        DO UPDATE SET
          count = caboose_metrics_days.count + EXCLUDED.count,
          sum_ms = caboose_metrics_days.sum_ms + EXCLUDED.sum_ms,
          error_count = caboose_metrics_days.error_count + EXCLUDED.error_count,
          updated_at = EXCLUDED.updated_at
      SQL
    end

    # MySQL upserts
    def mysql_upsert_hour(row, now)
      MetricHour.connection.execute(<<~SQL)
        INSERT INTO caboose_metrics_hours (bucket, namespace, service, target, operation, count, sum_ms, error_count, created_at, updated_at)
        VALUES (
          #{MetricHour.connection.quote(row.hour_bucket)},
          #{MetricHour.connection.quote(row.namespace)},
          #{MetricHour.connection.quote(row.service)},
          #{MetricHour.connection.quote(row.target)},
          #{MetricHour.connection.quote(row.operation)},
          #{row.total_count.to_i},
          #{row.total_sum_ms.to_i},
          #{row.total_error_count.to_i},
          #{MetricHour.connection.quote(now)},
          #{MetricHour.connection.quote(now)}
        )
        ON DUPLICATE KEY UPDATE
          count = count + VALUES(count),
          sum_ms = sum_ms + VALUES(sum_ms),
          error_count = error_count + VALUES(error_count),
          updated_at = VALUES(updated_at)
      SQL
    end

    def mysql_upsert_day(row, now)
      MetricDay.connection.execute(<<~SQL)
        INSERT INTO caboose_metrics_days (bucket, namespace, service, target, operation, count, sum_ms, error_count, created_at, updated_at)
        VALUES (
          #{MetricDay.connection.quote(row.day_bucket)},
          #{MetricDay.connection.quote(row.namespace)},
          #{MetricDay.connection.quote(row.service)},
          #{MetricDay.connection.quote(row.target)},
          #{MetricDay.connection.quote(row.operation)},
          #{row.total_count.to_i},
          #{row.total_sum_ms.to_i},
          #{row.total_error_count.to_i},
          #{MetricDay.connection.quote(now)},
          #{MetricDay.connection.quote(now)}
        )
        ON DUPLICATE KEY UPDATE
          count = count + VALUES(count),
          sum_ms = sum_ms + VALUES(sum_ms),
          error_count = error_count + VALUES(error_count),
          updated_at = VALUES(updated_at)
      SQL
    end

    # SQLite upserts
    def sqlite_upsert_hour(row, now)
      MetricHour.connection.execute(<<~SQL)
        INSERT INTO caboose_metrics_hours (bucket, namespace, service, target, operation, count, sum_ms, error_count, created_at, updated_at)
        VALUES (
          #{MetricHour.connection.quote(row.hour_bucket)},
          #{MetricHour.connection.quote(row.namespace)},
          #{MetricHour.connection.quote(row.service)},
          #{MetricHour.connection.quote(row.target)},
          #{MetricHour.connection.quote(row.operation)},
          #{row.total_count.to_i},
          #{row.total_sum_ms.to_i},
          #{row.total_error_count.to_i},
          #{MetricHour.connection.quote(now)},
          #{MetricHour.connection.quote(now)}
        )
        ON CONFLICT (bucket, namespace, service, target, operation)
        DO UPDATE SET
          count = count + excluded.count,
          sum_ms = sum_ms + excluded.sum_ms,
          error_count = error_count + excluded.error_count,
          updated_at = excluded.updated_at
      SQL
    end

    def sqlite_upsert_day(row, now)
      MetricDay.connection.execute(<<~SQL)
        INSERT INTO caboose_metrics_days (bucket, namespace, service, target, operation, count, sum_ms, error_count, created_at, updated_at)
        VALUES (
          #{MetricDay.connection.quote(row.day_bucket)},
          #{MetricDay.connection.quote(row.namespace)},
          #{MetricDay.connection.quote(row.service)},
          #{MetricDay.connection.quote(row.target)},
          #{MetricDay.connection.quote(row.operation)},
          #{row.total_count.to_i},
          #{row.total_sum_ms.to_i},
          #{row.total_error_count.to_i},
          #{MetricDay.connection.quote(now)},
          #{MetricDay.connection.quote(now)}
        )
        ON CONFLICT (bucket, namespace, service, target, operation)
        DO UPDATE SET
          count = count + excluded.count,
          sum_ms = sum_ms + excluded.sum_ms,
          error_count = error_count + excluded.error_count,
          updated_at = excluded.updated_at
      SQL
    end

    # Fallback for unknown databases
    def fallback_upsert_hour(row, now)
      record = MetricHour.find_or_initialize_by(
        bucket: row.hour_bucket,
        namespace: row.namespace,
        service: row.service,
        target: row.target,
        operation: row.operation
      )

      if record.persisted?
        record.count += row.total_count.to_i
        record.sum_ms += row.total_sum_ms.to_i
        record.error_count += row.total_error_count.to_i
      else
        record.count = row.total_count.to_i
        record.sum_ms = row.total_sum_ms.to_i
        record.error_count = row.total_error_count.to_i
      end

      record.save!
    end

    def fallback_upsert_day(row, now)
      record = MetricDay.find_or_initialize_by(
        bucket: row.day_bucket,
        namespace: row.namespace,
        service: row.service,
        target: row.target,
        operation: row.operation
      )

      if record.persisted?
        record.count += row.total_count.to_i
        record.sum_ms += row.total_sum_ms.to_i
        record.error_count += row.total_error_count.to_i
      else
        record.count = row.total_count.to_i
        record.sum_ms = row.total_sum_ms.to_i
        record.error_count = row.total_error_count.to_i
      end

      record.save!
    end
  end
end
