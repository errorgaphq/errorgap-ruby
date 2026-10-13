# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Errorgap
  # Sends every payload (notices, transactions, logs, sign-ins, releases) to
  # the ingestion API. Async sends go through one bounded queue drained by a
  # single worker thread, so a burst of errors cannot spawn a thread each or
  # hold the host's memory. A send that fails on the network or with a 5xx is
  # retried later; a 429 or 503 pauses all sending for the server's
  # `Retry-After`.
  class Delivery
    Result = Struct.new(:status, :body, :error, keyword_init: true) do
      def success?
        error.nil? && status.to_i.between?(200, 299)
      end
    end

    class RateLimited < StandardError; end

    MAX_ATTEMPTS = 3
    RETRY_DELAY = 30
    DEFAULT_RETRY_AFTER = 60
    MAX_RETRY_AFTER = 300
    BACKLOG_SIZE = 100
    FLUSH_TIMEOUT = 5

    Item = Struct.new(:resource, :payload, :attempt, :due_at)

    def initialize(configuration)
      @configuration = configuration
      @mutex = Mutex.new
      @work = ConditionVariable.new
      @idle = ConditionVariable.new
      @queue = []
      @backlog = []
      @in_flight = 0
      @paused_until = nil
      @worker = nil
      @pid = nil
    end

    def configure(configuration)
      @configuration = configuration
    end

    # Queue a payload and return at once. When the queue is full the oldest
    # entry is dropped, so the newest errors survive a burst.
    def enqueue(resource, payload)
      @mutex.synchronize do
        ensure_worker
        if @queue.length >= queue_size
          @queue.shift
          log("queue full, dropped the oldest payload")
        end
        @queue << Item.new(resource, payload, 1, nil)
        @work.signal
      end
      Result.new(status: 202, body: "queued")
    end

    # Send now, on the calling thread.
    def post(resource, payload)
      if paused?
        return Result.new(error: RateLimited.new("rate limited by the server, not sent"))
      end

      uri = URI.join(base_url, "api/projects/#{@configuration.project_slug}/#{resource}")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "errorgap-ruby/#{Errorgap::VERSION}"
      request["X-Errorgap-Project-Key"] = @configuration.api_key if present?(@configuration.api_key)
      request.body = JSON.generate(payload)

      timeout = http_timeout
      response = with_own_request do
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                                                open_timeout: timeout, read_timeout: timeout,
                                                write_timeout: timeout) do |http|
          http.request(request)
        end
      end
      status = response.code.to_i
      pause_for(response["Retry-After"]) if [429, 503].include?(status)
      Result.new(status: status, body: response.body)
    rescue StandardError => exception
      log("#{resource} delivery error: #{exception.class}: #{exception.message}")
      Result.new(error: exception)
    end

    # Wait for queued payloads to be sent. Payloads waiting for a retry are
    # not waited for.
    def flush(timeout = FLUSH_TIMEOUT)
      deadline = monotonic + timeout
      @mutex.synchronize do
        until @queue.empty? && @in_flight.zero?
          remaining = deadline - monotonic
          break if remaining <= 0 || !@worker&.alive?

          @idle.wait(@mutex, remaining)
        end
      end
      nil
    end

    def paused?
      until_time = @paused_until
      !until_time.nil? && monotonic < until_time
    end

    # True while this thread is sending to errorgap, so instrumentation can
    # leave the SDK's own requests out of the app's spans.
    def self.sending?
      Thread.current[:errorgap_sending] == true
    end

    private

    def with_own_request
      previous = Thread.current[:errorgap_sending]
      Thread.current[:errorgap_sending] = true
      yield
    ensure
      Thread.current[:errorgap_sending] = previous
    end

    # Called with the mutex held. A forked child (Puma workers, Sidekiq,
    # Passenger) has the parent's queue but not its thread: start clean.
    def ensure_worker
      if @pid != Process.pid
        @pid = Process.pid
        @queue = []
        @backlog = []
        @in_flight = 0
        @worker = nil
        install_exit_flush
      end
      return if @worker&.alive?

      @worker = Thread.new { run }
      @worker.name = "errorgap-delivery" if @worker.respond_to?(:name=)
      @worker.report_on_exception = false if @worker.respond_to?(:report_on_exception=)
    end

    def install_exit_flush
      pid = Process.pid
      at_exit { flush if Process.pid == pid }
    end

    def run
      loop do
        item = next_item
        result = post(item.resource, item.payload)
        @mutex.synchronize do
          retry_later(item) if retryable?(result)
          @in_flight -= 1
          @idle.broadcast if @queue.empty? && @in_flight.zero?
        end
      end
    rescue StandardError => exception
      log("delivery worker stopped: #{exception.class}: #{exception.message}")
    end

    def next_item
      @mutex.synchronize do
        loop do
          promote_due
          unless @queue.empty?
            @in_flight += 1
            return @queue.shift
          end
          @idle.broadcast
          @work.wait(@mutex, next_due_in)
        end
      end
    end

    def promote_due
      return if @backlog.empty?

      now = monotonic
      due, @backlog = @backlog.partition { |item| item.due_at <= now }
      @queue.concat(due)
    end

    def next_due_in
      return nil if @backlog.empty?

      [@backlog.map(&:due_at).min - monotonic, 0.05].max
    end

    # Network failures and 5xx responses are worth another try. A 4xx is not:
    # the server understood and refused, and after a 429 the payload is
    # dropped so a limited project is not sent the same burst again.
    def retryable?(result)
      return false if result.error.is_a?(RateLimited)
      return true if result.error

      result.status.to_i >= 500
    end

    def retry_later(item)
      return if item.attempt >= MAX_ATTEMPTS
      return if @backlog.length >= BACKLOG_SIZE

      @backlog << Item.new(item.resource, item.payload, item.attempt + 1,
                           monotonic + (RETRY_DELAY * item.attempt))
    end

    def pause_for(header)
      seconds = header.to_s.strip.match?(/\A\d+\z/) ? header.to_i : DEFAULT_RETRY_AFTER
      seconds = [[seconds, 1].max, MAX_RETRY_AFTER].min
      @paused_until = monotonic + seconds
      log("rate limited, pausing delivery for #{seconds}s")
    end

    def base_url
      endpoint = @configuration.endpoint.to_s
      endpoint.end_with?("/") ? endpoint : "#{endpoint}/"
    end

    def http_timeout
      value = @configuration.timeout.to_f
      value.positive? ? value : 5
    end

    def queue_size
      size = @configuration.queue_size.to_i
      size.positive? ? size : 100
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def log(message)
      @configuration.logger&.warn("[errorgap] #{message}")
    rescue StandardError
      nil
    end

    def present?(value)
      !value.nil? && !value.to_s.empty?
    end
  end
end
