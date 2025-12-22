# frozen_string_literal: true

require "securerandom"

module Caboose
  # Patch for Resque::Job to automatically track job execution.
  # This is prepended to Resque::Job to wrap the perform method.
  module ResqueJobPatch
    def perform
      return super unless Caboose.enabled?

      job_class = payload_class
      job_args = args || []
      case_uuid = SecureRandom.uuid
      started_at = Time.now
      queue_name = queue.to_s

      collector = Collector.new(case_uuid, started_at)
      Collector.push(collector)

      begin
        result = super

        duration_ms = ((Time.now - started_at) * 1000).round(2)

        save_caboose_case(
          uuid: case_uuid,
          type: "job",
          name: job_class.name,
          status: "completed",
          duration_ms: duration_ms,
          content: {
            queue_name: queue_name,
            args: sanitize_caboose_args(job_args)
          },
          started_at: started_at,
          clues: collector.clues
        )

        result
      rescue => e
        duration_ms = ((Time.now - started_at) * 1000).round(2)

        save_caboose_case(
          uuid: case_uuid,
          type: "job",
          name: job_class.name,
          status: "failed",
          duration_ms: duration_ms,
          content: {
            queue_name: queue_name,
            args: sanitize_caboose_args(job_args),
            error: e.class.name,
            error_message: e.message
          },
          started_at: started_at,
          clues: collector.clues
        )

        raise
      ensure
        Collector.pop
      end
    end

    private

    def save_caboose_case(attributes)
      clues = attributes.delete(:clues) || []
      Caboose.storage.save_case(attributes)
      Caboose.storage.save_clues(clues)
    rescue => e
      warn "[Caboose] Error saving Resque job case: #{e.message}"
    end

    def sanitize_caboose_args(args)
      args.map { |arg| sanitize_caboose_value(arg) }
    rescue
      ["[Unable to serialize args]"]
    end

    def sanitize_caboose_value(value)
      case value
      when Hash
        value.transform_keys(&:to_s).transform_values { |v| sanitize_caboose_value(v) }
      when Array
        value.map { |v| sanitize_caboose_value(v) }
      when String, Numeric, TrueClass, FalseClass, NilClass
        value
      when Symbol
        value.to_s
      else
        value.to_s
      end
    end
  end
end
