# frozen_string_literal: true

require "securerandom"

module Caboose
  module ActiveJobExtension
    extend ActiveSupport::Concern

    included do
      around_perform :caboose_track_job
    end

    private

    def caboose_track_job
      return yield unless Caboose.enabled?

      # If there's already a collector (e.g., inline job within a request),
      # just run the job and let the parent collector capture events
      if Collector.current
        return yield
      end

      case_uuid = SecureRandom.uuid
      started_at = Time.now

      collector = Collector.new(case_uuid, started_at)
      Collector.push(collector)

      begin
        yield

        duration_ms = ((Time.now - started_at) * 1000).round(2)

        caboose_save_case(
          uuid: case_uuid,
          type: "job",
          name: self.class.name,
          status: "completed",
          duration_ms: duration_ms,
          content: {
            job_id: job_id,
            queue_name: queue_name
          },
          started_at: started_at,
          clues: collector.clues
        )
      rescue => e
        duration_ms = ((Time.now - started_at) * 1000).round(2)

        caboose_save_case(
          uuid: case_uuid,
          type: "job",
          name: self.class.name,
          status: "failed",
          duration_ms: duration_ms,
          content: {
            job_id: job_id,
            queue_name: queue_name,
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

    def caboose_save_case(attributes)
      clues = attributes.delete(:clues) || []
      Caboose.storage.save_case(attributes)
      Caboose.storage.save_clues(clues)
    rescue => e
      warn "[Caboose] Error saving job case: #{e.message}"
    end
  end
end
