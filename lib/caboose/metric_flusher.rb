# frozen_string_literal: true

module Caboose
  # Background thread that periodically flushes in-memory metrics to the database.
  # Handles fork safety for Puma/Unicorn and graceful shutdown.
  class MetricFlusher
    DEFAULT_INTERVAL = 60 # seconds

    attr_reader :interval

    def initialize(storage:, submitter:, interval: DEFAULT_INTERVAL)
      @storage = storage
      @submitter = submitter
      @interval = interval
      @mutex = Mutex.new
      @thread = nil
      @running = false
      @pid = nil
    end

    # Start the background flush thread.
    # Safe to call multiple times - will only start one thread.
    def start
      @mutex.synchronize do
        return if @running && thread_alive?

        @running = true
        @pid = Process.pid
        @thread = Thread.new { run_flush_loop }
        @thread.name = "caboose-metric-flusher" if @thread.respond_to?(:name=)
      end
    end

    # Stop the background flush thread and perform final flush.
    def stop
      @mutex.synchronize do
        @running = false
        @thread&.wakeup rescue nil
      end

      # Wait for thread to finish (with timeout)
      @thread&.join(5)

      # Final flush to ensure no data loss
      flush_now
    end

    # Manually trigger a flush (useful for testing or forced flushes).
    def flush_now
      return 0 unless @storage && @submitter

      drained = @storage.drain
      return 0 if drained.empty?

      count, error = @submitter.submit(drained)
      if error
        warn "[Caboose] Metric submission error: #{error.message}"
      end
      count
    rescue => e
      warn "[Caboose] Metric flush error: #{e.message}"
      0
    end

    # Check if the flusher is running.
    def running?
      @running && thread_alive?
    end

    # Re-initialize after fork (call from Puma/Unicorn after_fork hooks).
    # This is necessary because threads don't survive fork.
    def after_fork
      @mutex.synchronize do
        # Thread from parent process is dead after fork
        @thread = nil

        # Restart if we were running before fork
        if @running
          @pid = Process.pid
          @thread = Thread.new { run_flush_loop }
          @thread.name = "caboose-metric-flusher" if @thread.respond_to?(:name=)
        end
      end
    end

    private

    def run_flush_loop
      while @running
        sleep_with_interrupt(@interval)

        # Check if we're in a forked process (thread should have been restarted)
        if Process.pid != @pid
          break
        end

        next unless @running

        flush_now
      end
    rescue => e
      warn "[Caboose] Metric flusher crashed: #{e.message}"
      # Don't restart automatically - let the app handle it
    end

    def sleep_with_interrupt(seconds)
      # Sleep in small increments so we can respond to stop quickly
      remaining = seconds
      while remaining > 0 && @running
        sleep_time = [remaining, 1.0].min
        sleep(sleep_time)
        remaining -= sleep_time
      end
    end

    def thread_alive?
      @thread&.alive? && Process.pid == @pid
    end
  end
end
