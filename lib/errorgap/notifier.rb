# frozen_string_literal: true

module Errorgap
  class Notifier
    Response = Struct.new(:status, :body, :error, keyword_init: true) do
      def success?
        error.nil? && status.to_i.between?(200, 299)
      end
    end

    def initialize(configuration)
      configure(configuration)
    end

    def configure(configuration)
      @configuration = configuration
    end

    def notify(error, context: {}, environment: {}, session: {}, params: {}, breadcrumbs: [], sync: false)
      @configuration.validate!
      return Response.new(status: 202, body: "ignored environment") if @configuration.ignored_environment?
      unless Errorgap.remote_settings.enabled?(:errors)
        return Response.new(status: 202, body: "errors are switched off for this project")
      end

      notice = Notice.from_exception(
        error,
        configuration: @configuration,
        context: context,
        environment: environment,
        session: session,
        params: params,
        breadcrumbs: breadcrumbs
      )
      payload = run_hooks(notice.to_h)
      return Response.new(status: 202, body: "dropped by before_notify") unless payload

      Errorgap.record_release_once if @configuration.track_release

      if sync || !@configuration.async
        deliver(payload)
      else
        Errorgap.delivery.enqueue("notices", payload)
        Response.new(status: 202, body: "queued")
      end
    rescue StandardError => exception
      log(exception)
      Response.new(error: exception)
    end

    # `notice` is a Notice or an already built payload Hash.
    def deliver(notice)
      payload = notice.respond_to?(:to_h) && !notice.is_a?(Hash) ? notice.to_h : notice
      result = Errorgap.delivery.post("notices", payload)
      Response.new(status: result.status, body: result.body, error: result.error)
    rescue StandardError => exception
      log(exception)
      Response.new(error: exception)
    end

    private

    # A hook that raises is logged and skipped: a bug in a filter must not
    # lose the error it was filtering.
    def run_hooks(payload)
      @configuration.before_notify_hooks.each do |hook|
        begin
          result = hook.call(payload)
        rescue StandardError => exception
          log(exception)
          next
        end
        return nil if result == false

        payload = result if result.is_a?(Hash) && result.key?(:errors)
      end
      payload
    end

    def log(exception)
      @configuration.logger&.warn("[errorgap] #{exception.class}: #{exception.message}")
    end
  end
end
