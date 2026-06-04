# frozen_string_literal: true

module Errorgap
  class RackMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      SpanCollector.start if apm_enabled?

      status, headers, body = @app.call(env)
      [status, headers, body]
    rescue Exception => exception # rubocop:disable Lint/RescueException
      notify_once(env, exception)
      raise
    ensure
      if apm_enabled?
        elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000.0
        record_transaction(env, status || 500, elapsed_ms)
      end
    end

    private

    def apm_enabled?
      Errorgap.configuration.apm_enabled
    end

    def record_transaction(env, status_code, elapsed_ms)
      spans = SpanCollector.flush
      txn = Transaction.new(
        kind: "web",
        method: env["REQUEST_METHOD"],
        path: route_pattern(env),
        path_raw: env["PATH_INFO"],
        status_code: status_code,
        duration_ms: elapsed_ms.round(2),
        environment: Errorgap.configuration.environment,
        occurred_at: Time.now,
        spans: spans
      )
      Errorgap.transacter.deliver_async(txn)
    rescue StandardError => exception
      Errorgap.configuration.logger&.warn("[errorgap] APM record error: #{exception.message}")
    end

    def route_pattern(env)
      # Rails: use controller#action as the normalised route pattern
      if (params = env["action_dispatch.request.path_parameters"])
        controller = params[:controller]
        action = params[:action]
        return "#{controller}##{action}" if controller && action
      end

      # Sinatra: env['sinatra.route'] is "GET /path/:id"
      if (sinatra_route = env["sinatra.route"])
        return sinatra_route.split(" ", 2).last
      end

      # Plain Rack fallback
      env["PATH_INFO"]
    end

    def notify_once(env, exception)
      notified = env["errorgap.notified_exception_ids"] ||= {}
      return if notified[exception.object_id]

      notified[exception.object_id] = true
      Errorgap.notify(
        exception,
        context: rack_context(env),
        environment: rack_environment(env),
        session: rack_session(env),
        params: rack_params(env),
        sync: true
      )
    end

    def rack_context(env)
      {
        url: "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}#{env['PATH_INFO']}",
        component: env["SCRIPT_NAME"],
        action: env["REQUEST_METHOD"]
      }
    end

    def rack_environment(env)
      {
        method: env["REQUEST_METHOD"],
        path: env["PATH_INFO"],
        query_string: env["QUERY_STRING"],
        user_agent: env["HTTP_USER_AGENT"],
        remote_addr: env["REMOTE_ADDR"]
      }
    end

    def rack_session(env)
      session = env["rack.session"]
      session.respond_to?(:to_hash) ? session.to_hash : {}
    end

    def rack_params(env)
      request = defined?(Rack::Request) ? Rack::Request.new(env) : nil
      request ? request.params : {}
    rescue StandardError
      {}
    end
  end
end
