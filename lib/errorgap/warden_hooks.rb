# frozen_string_literal: true

module Errorgap
  # Devise and other Warden apps: report sign-ins without touching the
  # controllers. The Rails railtie installs these when `auth_events` is on;
  # elsewhere call `Errorgap::WardenHooks.install` after configuring.
  module WardenHooks
    # Failures that are not a sign-in attempt: visiting a protected page
    # signed out, an expired session, an account that is not confirmed.
    NOT_ATTEMPTS = %i[unauthenticated timeout inactive unconfirmed].freeze
    # Form fields that hold the name being signed in with.
    USER_PARAMS = %w[email login username].freeze

    class << self
      def install
        return false unless defined?(::Warden::Manager)
        return true if @installed

        ::Warden::Manager.after_authentication do |user, auth, opts|
          Errorgap::WardenHooks.on_success(user, auth, opts)
        end
        ::Warden::Manager.before_failure do |env, opts|
          Errorgap::WardenHooks.on_failure(env, opts)
        end
        @installed = true
      end

      def on_success(user, auth, _opts = {})
        # A remember-me cookie signing the user back in is not a new sign-in.
        return if auth.respond_to?(:winning_strategy) && auth.winning_strategy.respond_to?(:key) &&
                  auth.winning_strategy.key == :rememberable

        Errorgap.sign_in("success", user: identify(user), request: request_for(auth.env))
      rescue StandardError => exception
        Errorgap.configuration.logger&.warn("[errorgap] sign-in hook error: #{exception.class}: #{exception.message}")
      end

      def on_failure(env, opts = {})
        message = opts[:message]&.to_sym
        return if NOT_ATTEMPTS.include?(message)

        request = request_for(env)
        return unless request&.post?

        outcome = message == :locked ? "locked" : "failure"
        # Warden points PATH_INFO at the failure app before this runs; the
        # form's path is in `attempted_path` (query string dropped).
        path = opts[:attempted_path] ? "#{request.request_method} #{opts[:attempted_path].to_s.split('?').first}" : nil
        Errorgap.sign_in(outcome, user: attempted_user(request, opts[:scope]), request: request, path: path)
      rescue StandardError => exception
        Errorgap.configuration.logger&.warn("[errorgap] sign-in hook error: #{exception.class}: #{exception.message}")
      end

      # How a signed-in user is named: `config.auth_user` (a method name or a
      # proc), else email, username, login, then id.
      def identify(user)
        pick = Errorgap.configuration.auth_user
        return pick.call(user) if pick.respond_to?(:call)
        return user.public_send(pick) if pick && user.respond_to?(pick)

        %i[email username login id].each do |name|
          return user.public_send(name) if user.respond_to?(name)
        end
        nil
      end

      private

      def attempted_user(request, scope)
        params = request.params
        fields = scope && params[scope.to_s].is_a?(Hash) ? params[scope.to_s] : params
        USER_PARAMS.each do |name|
          value = fields[name]
          return value if value.is_a?(String) && !value.strip.empty?
        end
        nil
      end

      def request_for(env)
        if defined?(::ActionDispatch::Request)
          ::ActionDispatch::Request.new(env)
        elsif defined?(::Rack::Request)
          ::Rack::Request.new(env)
        end
      end
    end
  end
end
