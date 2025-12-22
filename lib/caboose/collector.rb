# frozen_string_literal: true

module Caboose
  class Collector
    class << self
      def current
        stack.last
      end

      def push(collector)
        stack.push(collector)
        collector
      end

      def pop
        stack.pop
      end

      def clear
        Thread.current[:caboose_collector_stack] = nil
      end

      private

      def stack
        Thread.current[:caboose_collector_stack] ||= []
      end
    end

    attr_reader :case_uuid, :started_at, :parent_case_uuid

    def initialize(case_uuid, started_at, parent_case_uuid: nil)
      @case_uuid = case_uuid
      @started_at = started_at
      @parent_case_uuid = parent_case_uuid
      @clues = []
      @mutex = Mutex.new
    end

    def record(type, started_at:, duration_ms:, content:)
      offset_ms = ((started_at - @started_at) * 1000).round(2)
      @mutex.synchronize do
        @clues << {
          case_uuid: @case_uuid,
          type: type,
          started_at_offset_ms: offset_ms,
          duration_ms: duration_ms,
          content: content
        }
      end
    end

    def clues
      @mutex.synchronize { @clues.dup }
    end
  end
end
