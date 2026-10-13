# frozen_string_literal: true

require "rails/railtie"

module Errorgap
  module Rails
    class Railtie < ::Rails::Railtie
      initializer "errorgap.configure_rails" do |app|
        Errorgap.configure do |config|
          config.root_directory = app.root.to_s
          config.environment = ::Rails.env.to_s
          config.logger = ::Rails.logger
        end
      end

      initializer "errorgap.insert_middleware" do |app|
        app.config.middleware.use Errorgap::RackMiddleware
      end

      initializer "errorgap.install_span_collector" do
        # Unconditional: apps enable APM in config/initializers, which runs
        # after railtie initializers, so the flag cannot be checked here. The
        # subscribers no-op unless the middleware starts a per-request
        # collection, which does check the flag.
        SpanCollector.install
        Errorgap::Integrations::NetHTTP.install
      end

      # Background jobs: report their errors and time them. Like the span
      # collector these check the configuration when a job runs.
      initializer "errorgap.install_job_integrations" do
        Errorgap::Integrations::ActiveJob.install
        Errorgap::Integrations::Sidekiq.install
      end

      # After config/initializers, so `auth_events` is readable here.
      config.after_initialize do
        Errorgap::WardenHooks.install if Errorgap.configuration.auth_events
      end

      generators do
        require "generators/errorgap/install_generator"
      end
    end
  end
end
