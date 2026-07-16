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
      end

      generators do
        require "generators/errorgap/install_generator"
      end
    end
  end
end
