# frozen_string_literal: true

require "securerandom"

require_relative "errorgap/configuration"
require_relative "errorgap/sanitizer"
require_relative "errorgap/release_detector"
require_relative "errorgap/delivery"
require_relative "errorgap/breadcrumbs"
require_relative "errorgap/notifier"
require_relative "errorgap/notice"
require_relative "errorgap/log_delivery"
require_relative "errorgap/sign_ins"
require_relative "errorgap/warden_hooks"
require_relative "errorgap/transaction"
require_relative "errorgap/span_collector"
require_relative "errorgap/span_recorder"
require_relative "errorgap/transacter"
require_relative "errorgap/rack_middleware"
require_relative "errorgap/integrations/sidekiq"
require_relative "errorgap/integrations/active_job"
require_relative "errorgap/integrations/net_http"
require_relative "errorgap/version"

module Errorgap
  class << self
    def configure
      yield(configuration)
      delivery.configure(configuration)
      notifier.configure(configuration)
      transacter.configure(configuration)
      log_delivery.configure(configuration)
      sign_ins.configure(configuration)
      @breadcrumbs = Breadcrumbs.new(configuration.max_breadcrumbs)
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def notifier
      @notifier ||= Notifier.new(configuration)
    end

    # The shared sender behind notices, transactions, logs and sign-ins.
    def delivery
      @delivery ||= Delivery.new(configuration)
    end

    def transacter
      @transacter ||= Transacter.new(configuration)
    end

    def log_delivery
      @log_delivery ||= LogDelivery.new(configuration)
    end

    def sign_ins
      @sign_ins ||= SignIns.new(configuration)
    end

    # Report a sign-in to this app: "success", "failure", "password_reset",
    # "mfa_failure" or "locked". Pass the request for its IP, user agent and
    # path. Needs `config.auth_events = true`; Devise apps get this
    # automatically from the Warden hooks.
    def sign_in(outcome, user: nil, request: nil, ip: nil, user_agent: nil, path: nil, method: nil, sync: false)
      sign_ins.record(outcome, user: user, request: request, ip: ip, user_agent: user_agent,
                               path: path, method: method, sync: sync)
    end

    def breadcrumbs
      @breadcrumbs ||= Breadcrumbs.new(configuration.max_breadcrumbs)
    end

    def notify(error, context: {}, environment: {}, session: {}, params: {}, sync: false)
      # The request or job this error was raised in, so errorgap links the two.
      if (transaction_id = current_transaction_id) && !context.key?(:transaction_id) && !context.key?("transaction_id")
        context = context.merge(transaction_id: transaction_id)
      end
      session = user_session.merge(session || {}) if current_user
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

    REPORTED_IVAR = :@__errorgap_reported
    USER_KEY = :errorgap_user

    # `notify`, unless this exception object was already reported: lets the
    # Rack middleware, a job integration and the app's own rescue all see the
    # same error without sending it more than once.
    def notify_once(error, **options)
      return nil if reported?(error)

      mark_reported(error)
      notify(error, **options)
    end

    def reported?(error)
      error.instance_variable_defined?(REPORTED_IVAR)
    rescue StandardError
      false
    end

    def mark_reported(error)
      error.instance_variable_set(REPORTED_IVAR, true) unless error.frozen?
    rescue StandardError
      nil
    end

    # Name the user the current request or job is acting for. Errors reported
    # on this thread until `clear_user` carry it as `session.user_id` /
    # `session.user_email`, which errorgap's user filters read.
    def set_user(id: nil, email: nil)
      user = {}
      user[:id] = id.to_s unless id.nil? || id.to_s.empty?
      user[:email] = email.to_s unless email.nil? || email.to_s.empty?
      Thread.current[USER_KEY] = user.empty? ? nil : user
    end

    def clear_user
      Thread.current[USER_KEY] = nil
    end

    def current_user
      Thread.current[USER_KEY]
    end

    # Record a release with errorgap (Deploys): errors are then attributed to
    # the deploy that shipped them. Defaults come from the configuration.
    def track_release(version: nil, sha: nil, branch: nil, environment: nil, sync: true)
      configuration.validate!
      return if configuration.ignored_environment?

      payload = {
        version: version || configuration.release,
        sha: sha || configuration.release_sha,
        branch: branch || configuration.release_branch,
        environment: environment || configuration.environment
      }.compact
      return unless payload[:version] || payload[:sha]

      if sync
        delivery.post("releases", payload)
      else
        delivery.enqueue("releases", payload)
      end
    rescue StandardError => exception
      configuration.logger&.warn("[errorgap] release not recorded: #{exception.class}: #{exception.message}")
      nil
    end

    # `config.track_release`: the first notice of a process records the
    # release, so an app that never errors never calls errorgap.
    def record_release_once
      return if @release_recorded

      @release_recorded = true
      track_release(sync: false)
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

    TRANSACTION_ID_KEY = :errorgap_transaction_id

    # The id of the APM transaction running on this fiber, if any. Notices
    # reported while it is set carry it as `context.transaction_id`.
    def current_transaction_id
      Thread.current[TRANSACTION_ID_KEY]
    end

    # Run the block as one transaction: a new id is current for its duration
    # (fiber-local, so concurrent requests never share one) and the previous
    # one is restored after. Yields the id.
    def with_transaction_id
      previous = Thread.current[TRANSACTION_ID_KEY]
      id = SecureRandom.uuid
      Thread.current[TRANSACTION_ID_KEY] = id
      yield id
    ensure
      Thread.current[TRANSACTION_ID_KEY] = previous
    end

    # Deliver a prebuilt APM transaction, honoring apm_enabled and sampling.
    def notify_transaction(transaction, sync: false)
      return unless configuration.apm_enabled
      return if configuration.ignored_environment?
      return unless sample_apm?

      if sync || !configuration.async
        transacter.deliver(transaction)
      else
        delivery.enqueue("transactions", transaction.to_h)
      end
    end

    # Time an HTTP interaction and deliver it as a transaction. The block
    # receives a SpanRecorder for manual DB/HTTP spans; any automatic
    # `sql.active_record` spans recorded during the block are merged in.
    def track_transaction(method: nil, path: nil, path_raw: nil, status_code: nil, kind: "web", environment: nil, sync: false)
      with_transaction_id do |transaction_id|
        SpanCollector.start
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        occurred = Time.now
        begin
          yield(SpanRecorder.new) if block_given?
        ensure
          elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
          transaction = Transaction.new(
            id: transaction_id,
            kind: kind, method: method, path: path, path_raw: path_raw,
            status_code: status_code, duration_ms: elapsed_ms.round(2),
            environment: environment || configuration.environment,
            occurred_at: occurred, spans: SpanCollector.flush
          )
          notify_transaction(transaction, sync: sync)
        end
      end
    end

    # Time a background job and deliver it as a `job` transaction.
    def track_job(job_class, queue: "default", environment: nil, sync: false)
      with_transaction_id do |transaction_id|
        SpanCollector.start
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        occurred = Time.now
        begin
          yield(SpanRecorder.new) if block_given?
        ensure
          elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
          transaction = Transaction.new(
            id: transaction_id,
            kind: "job", job_class: job_class, queue: queue,
            duration_ms: elapsed_ms.round(2),
            environment: environment || configuration.environment,
            occurred_at: occurred, spans: SpanCollector.flush
          )
          notify_transaction(transaction, sync: sync)
        end
      end
    end

    # Wait for queued notices, transactions and logs to be sent. Call before
    # process exit; queued payloads are also flushed from an `at_exit` hook.
    def flush(timeout = Delivery::FLUSH_TIMEOUT)
      delivery.flush(timeout)
      threads = thread_mutex.synchronize do
        pending = delivery_threads.dup
        delivery_threads.clear
        pending
      end
      threads.each { |thread| thread.join(timeout) }
      nil
    end

    # Kept for callers that run their own delivery threads.
    def register_thread(thread)
      thread_mutex.synchronize do
        delivery_threads.select!(&:alive?)
        delivery_threads << thread
      end
      thread
    end

    private

    def user_session
      user = current_user || {}
      session = {}
      session["user_id"] = user[:id] if user[:id]
      session["user_email"] = user[:email] if user[:email]
      session
    end

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
