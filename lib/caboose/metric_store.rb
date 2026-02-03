# frozen_string_literal: true

module Caboose
  # Persists aggregated metrics to the database using ActiveRecord.
  # Uses upsert to merge in-memory counters with stored data.
  class MetricStore
    # Flush metrics from in-memory storage to the database.
    # Drains the storage and upserts each metric.
    # Returns the number of metrics flushed.
    def flush(storage)
      data = storage.drain
      return 0 if data.empty?

      now = Time.current

      # Use transaction for atomicity
      Metric.transaction do
        data.each do |key, counter|
          upsert_metric(key, counter, now)
        end
      end

      data.size
    end

    # Query metrics with optional filters.
    def query(namespace: nil, service: nil, target: nil, operation: nil,
              start_time: nil, end_time: nil, limit: 1000)
      scope = Metric.all
      scope = scope.for_namespace(namespace) if namespace
      scope = scope.for_service(service) if service
      scope = scope.for_target(target) if target
      scope = scope.for_operation(operation) if operation
      scope = scope.since(start_time) if start_time
      scope = scope.until(end_time) if end_time
      scope.order(bucket: :desc).limit(limit)
    end

    # Aggregate metrics by a dimension.
    def aggregate_by(dimension, namespace: nil, service: nil, start_time: nil, end_time: nil)
      scope = Metric.all
      scope = scope.for_namespace(namespace) if namespace
      scope = scope.for_service(service) if service
      scope = scope.since(start_time) if start_time
      scope = scope.until(end_time) if end_time
      scope.aggregate_by(dimension)
    end

    # Delete metrics older than the specified time.
    def prune(before:)
      Metric.where("bucket < ?", before).delete_all
    end

    # Delete all metrics.
    def clear_all
      Metric.delete_all
    end

    # Count total metrics.
    def count
      Metric.count
    end

    private

    def upsert_metric(key, counter, now)
      # Convert nil target to empty string for consistent uniqueness
      target = key.target.to_s

      # Use database-agnostic upsert via raw SQL
      adapter = Metric.connection.adapter_name.downcase

      case adapter
      when /postgresql/
        postgresql_upsert(key, target, counter, now)
      when /mysql/
        mysql_upsert(key, target, counter, now)
      when /sqlite/
        sqlite_upsert(key, target, counter, now)
      else
        # Fallback: find_or_create + increment (slower but universal)
        fallback_upsert(key, target, counter, now)
      end
    end

    def postgresql_upsert(key, target, counter, now)
      Metric.connection.execute(
        Metric.sanitize_sql_array([<<~SQL, key.bucket, key.namespace, key.service, target, key.operation, counter[:count], counter[:sum_ms], counter[:error_count], now, now, counter[:count], counter[:sum_ms], counter[:error_count], now])
          INSERT INTO caboose_metrics (bucket, namespace, service, target, operation, count, sum_ms, error_count, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (bucket, namespace, service, target, operation)
          DO UPDATE SET
            count = caboose_metrics.count + ?,
            sum_ms = caboose_metrics.sum_ms + ?,
            error_count = caboose_metrics.error_count + ?,
            updated_at = ?
        SQL
      )
    end

    def mysql_upsert(key, target, counter, now)
      Metric.connection.execute(
        Metric.sanitize_sql_array([<<~SQL, key.bucket, key.namespace, key.service, target, key.operation, counter[:count], counter[:sum_ms], counter[:error_count], now, now, counter[:count], counter[:sum_ms], counter[:error_count], now])
          INSERT INTO caboose_metrics (bucket, namespace, service, target, operation, count, sum_ms, error_count, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON DUPLICATE KEY UPDATE
            count = count + ?,
            sum_ms = sum_ms + ?,
            error_count = error_count + ?,
            updated_at = ?
        SQL
      )
    end

    def sqlite_upsert(key, target, counter, now)
      Metric.connection.execute(
        Metric.sanitize_sql_array([<<~SQL, key.bucket, key.namespace, key.service, target, key.operation, counter[:count], counter[:sum_ms], counter[:error_count], now, now, counter[:count], counter[:sum_ms], counter[:error_count], now])
          INSERT INTO caboose_metrics (bucket, namespace, service, target, operation, count, sum_ms, error_count, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (bucket, namespace, service, target, operation)
          DO UPDATE SET
            count = count + ?,
            sum_ms = sum_ms + ?,
            error_count = error_count + ?,
            updated_at = ?
        SQL
      )
    end

    def fallback_upsert(key, target, counter, now)
      metric = Metric.find_or_initialize_by(
        bucket: key.bucket,
        namespace: key.namespace,
        service: key.service,
        target: target,
        operation: key.operation
      )

      if metric.persisted?
        metric.count += counter[:count]
        metric.sum_ms += counter[:sum_ms]
        metric.error_count += counter[:error_count]
      else
        metric.count = counter[:count]
        metric.sum_ms = counter[:sum_ms]
        metric.error_count = counter[:error_count]
      end

      metric.save!
    end
  end
end
