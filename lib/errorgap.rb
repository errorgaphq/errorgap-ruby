# frozen_string_literal: true

require_relative "errorgap/configuration"
require_relative "errorgap/breadcrumbs"
require_relative "errorgap/notifier"
require_relative "errorgap/notice"
require_relative "errorgap/log_delivery"
require_relative "errorgap/transaction"
require_relative "errorgap/span_collector"
require_relative "errorgap/span_recorder"
require_relative "errorgap/transacter"
require_relative "errorgap/rack_middleware"
require_relative "errorgap/version"

module Errorgap
  class << self
    def configure
      yield(configuration)
      notifier.configure(configuration)
      transacter.configure(configuration)
      log_delivery.configure(configuration)
      @breadcrumbs = Breadcrumbs.new(configuration.max_breadcrumbs)
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def notifier
      @notifier ||= Notifier.new(configuration)
    end

    def transacter
      @transacter ||= Transacter.new(configuration)
    end

    def log_delivery
      @log_delivery ||= LogDelivery.new(configuration)
    end

    def breadcrumbs
      @breadcrumbs ||= Breadcrumbs.new(configuration.max_breadcrumbs)
    end

    def notify(error, context: {}, environment: {}, session: {}, params: {}, sync: false)
      notifier.notify(
        error,
        context: context,
        environment: environment,
        session: session,
        params: params,
        breadcrumbs: breadcrumbs.to_a,
        sync: sync
      )
    end

    # Record a diagnostic breadcrumb attached to subsequent notices.
    def add_breadcrumb(message, category: nil, metadata: nil)
      breadcrumbs.add(message, category: category, metadata: metadata)
    end

    def clear_breadcrumbs
      breadcrumbs.clear
    end

    # Deliver a structured log line at the given level.
    def log(message, level: "info", source: nil, environment: nil, occurred_at: nil, sync: false)
      log_delivery.log(
        message,
        level: level,
        source: source,
        environment: environment,
        occurred_at: occurred_at,
        sync: sync
      )
    end

    # Deliver a prebuilt APM transaction, honoring apm_enabled and sampling.
    def notify_transaction(transaction, sync: false)
      return unless configuration.apm_enabled
      return if configuration.ignored_environment?
      return unless sample_apm?

      if sync || !configuration.async
        transacter.deliver(transaction)
      else
        register_thread(Thread.new { transacter.deliver(transaction) })
      end
    end

    # Time an HTTP interaction and deliver it as a transaction. The block
    # receives a SpanRecorder for manual DB/HTTP spans; any automatic
    # `sql.active_record` spans recorded during the block are merged in.
    def track_transaction(method: nil, path: nil, path_raw: nil, status_code: nil, kind: "web", environment: nil, sync: false)
      SpanCollector.start
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      occurred = Time.now
      begin
        yield(SpanRecorder.new) if block_given?
      ensure
        elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        transaction = Transaction.new(
          kind: kind, method: method, path: path, path_raw: path_raw,
          status_code: status_code, duration_ms: elapsed_ms.round(2),
          environment: environment || configuration.environment,
          occurred_at: occurred, spans: SpanCollector.flush
        )
        notify_transaction(transaction, sync: sync)
      end
    end

    # Time a background job and deliver it as a `job` transaction.
    def track_job(job_class, queue: "default", environment: nil, sync: false)
      SpanCollector.start
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      occurred = Time.now
      begin
        yield(SpanRecorder.new) if block_given?
      ensure
        elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        transaction = Transaction.new(
          kind: "job", job_class: job_class, queue: queue,
          duration_ms: elapsed_ms.round(2),
          environment: environment || configuration.environment,
          occurred_at: occurred, spans: SpanCollector.flush
        )
        notify_transaction(transaction, sync: sync)
      end
    end

    # Join any in-flight async delivery threads. Call before process exit to
    # avoid dropping queued notices/transactions/logs.
    def flush
      threads = thread_mutex.synchronize do
        pending = delivery_threads.dup
        delivery_threads.clear
        pending
      end
      threads.each { |thread| thread.join(5) }
      nil
    end

    def register_thread(thread)
      thread_mutex.synchronize { delivery_threads << thread }
      thread
    end

    private

    def sample_apm?
      rate = configuration.apm_sample_rate.to_f
      return true if rate >= 1.0
      return false if rate <= 0.0

      rand < rate
    end

    def delivery_threads
      @delivery_threads ||= []
    end

    def thread_mutex
      @thread_mutex ||= Mutex.new
    end
  end
end

require_relative "errorgap/rails/railtie" if defined?(Rails::Railtie)
