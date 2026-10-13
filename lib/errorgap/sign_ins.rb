# frozen_string_literal: true

require "time"

module Errorgap
  # Sign-ins to this app, shown beside SSH logins in Security › Logins.
  # Opt in with `config.auth_events = true`. Only who, from where and the
  # result are sent: never passwords, tokens or session ids.
  class SignIns
    OUTCOMES = %w[success failure password_reset mfa_failure locked].freeze

    def initialize(configuration)
      configure(configuration)
    end

    def configure(configuration)
      @configuration = configuration
    end

    # `request` (Rack or ActionDispatch) fills in the IP, user agent and path.
    def record(outcome, user: nil, request: nil, ip: nil, user_agent: nil, path: nil, method: nil,
               occurred_at: nil, sync: false)
      return unless @configuration.auth_events
      return if @configuration.ignored_environment?

      outcome = outcome.to_s
      unless OUTCOMES.include?(outcome)
        @configuration.logger&.warn("[errorgap] unknown sign-in outcome #{outcome.inspect}")
        return
      end

      if request
        ip ||= request.respond_to?(:remote_ip) ? request.remote_ip : request.ip
        user_agent ||= request.user_agent
        path ||= "#{request.request_method} #{request.path}"
      end
      event = { occurred_at: (occurred_at || Time.now).utc.iso8601(3), outcome: outcome }
      event[:user] = user.to_s if present?(user)
      event[:ip] = ip.to_s if present?(ip)
      event[:user_agent] = user_agent.to_s[0, 512] if present?(user_agent)
      event[:path] = path.to_s[0, 200] if present?(path)
      event[:method] = method.to_s if present?(method)
      payload = {
        app: @configuration.app_name || @configuration.project_slug,
        environment: @configuration.environment,
        sdk: "errorgap-ruby #{Errorgap::VERSION}",
        events: [event]
      }

      if sync || !@configuration.async
        deliver(payload)
      else
        Errorgap.delivery.enqueue("logins/web", payload)
        nil
      end
    end

    def deliver(payload)
      Errorgap.delivery.post("logins/web", payload)
    end

    private

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end
  end
end
