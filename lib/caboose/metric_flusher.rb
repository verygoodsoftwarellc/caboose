# frozen_string_literal: true

require "concurrent/timer_task"
require "concurrent/executor/fixed_thread_pool"

module Caboose
  # Background threads that periodically drain in-memory metrics and submit
  # them via HTTP. Uses concurrent-ruby TimerTask + FixedThreadPool, matching
  # the pattern in Flipper's telemetry.
  #
  # Fork-safe: detects forked processes and restarts automatically.
  class MetricFlusher
    DEFAULT_INTERVAL = 60 # seconds
    DEFAULT_SHUTDOWN_TIMEOUT = 5 # seconds

    attr_reader :interval, :shutdown_timeout

    def initialize(storage:, submitter:, interval: DEFAULT_INTERVAL, shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT)
      @storage = storage
      @submitter = submitter
      @interval = interval
      @shutdown_timeout = shutdown_timeout
      @pid = $$
    end

    def start
      @pool = Concurrent::FixedThreadPool.new(1, {
        max_queue: 20,
        fallback_policy: :discard,
        name: "caboose-metrics-submit-pool".freeze,
      })

      @timer = Concurrent::TimerTask.execute({
        execution_interval: @interval,
        name: "caboose-metrics-drain-timer".freeze,
      }) { post_to_pool }
    end

    def stop
      if @timer
        @timer.shutdown
        @timer.wait_for_termination(1)
        @timer.kill unless @timer.shutdown?
      end

      if @pool
        post_to_pool # one last drain
        @pool.shutdown
        pool_terminated = @pool.wait_for_termination(@shutdown_timeout)
        @pool.kill unless pool_terminated
      end
    end

    def restart
      stop
      start
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

    def running?
      @timer&.running? || false
    end

    # Re-initialize after fork (call from Puma/Unicorn after_fork hooks).
    def after_fork
      detect_forking
    end

    private

    def detect_forking
      if @pid != $$
        restart
        @pid = $$
      end
    end

    def post_to_pool
      detect_forking

      drained = @storage.drain
      if drained.empty?
        Caboose.log "No metrics to flush"
        return
      end

      Caboose.log "Drained #{drained.size} metric keys for submission"
      @pool.post { submit_to_cloud(drained) }
    rescue => e
      warn "[Caboose] Metric drain error: #{e.message}"
    end

    def submit_to_cloud(drained)
      _response, error = @submitter.submit(drained)
      if error
        warn "[Caboose] Metric submission error: #{error.message}"
      end
    rescue => e
      warn "[Caboose] Metric submission error: #{e.message}"
    end
  end
end
