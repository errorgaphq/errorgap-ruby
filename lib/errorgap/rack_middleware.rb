# frozen_string_literal: true

module Errorgap
  class RackMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env)
    rescue Exception => exception # rubocop:disable Lint/RescueException
      notify_once(env, exception)
      raise
    end

    private

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
