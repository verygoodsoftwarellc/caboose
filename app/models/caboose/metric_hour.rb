# frozen_string_literal: true

module Caboose
  class MetricHour < ActiveRecord::Base
    self.table_name = "caboose_metrics_hours"

    # Valid dimensions for aggregation (whitelist for safety)
    DIMENSIONS = {
      "namespace" => :namespace,
      "service" => :service,
      "target" => :target,
      "operation" => :operation
    }.freeze

    validates :bucket, presence: true
    validates :namespace, presence: true
    validates :service, presence: true
    validates :operation, presence: true

    # Scopes for common queries
    scope :for_namespace, ->(namespace) { where(namespace: namespace) }
    scope :for_service, ->(service) { where(service: service) }
    scope :for_target, ->(target) { where(target: target) }
    scope :for_operation, ->(operation) { where(operation: operation) }
    scope :since, ->(time) { where("bucket >= ?", time) }
    scope :until, ->(time) { where("bucket <= ?", time) }
    scope :recent, ->(duration = 24.hours) { since(duration.ago) }

    # Aggregate metrics by a dimension
    def self.aggregate_by(dimension)
      column = DIMENSIONS[dimension.to_s]
      raise ArgumentError, "Invalid dimension: #{dimension}. Valid: #{DIMENSIONS.keys.join(', ')}" unless column

      group(column)
        .select(
          column,
          "SUM(count) as total_count",
          "SUM(sum_ms) as total_sum_ms",
          "SUM(error_count) as total_error_count"
        )
        .order("total_count DESC")
    end

    # Calculate average duration
    def avg_ms
      return 0 if count.zero?
      (sum_ms.to_f / count).round(2)
    end

    # Calculate error rate as percentage
    def error_rate
      return 0.0 if count.zero?
      ((error_count.to_f / count) * 100).round(2)
    end
  end
end
