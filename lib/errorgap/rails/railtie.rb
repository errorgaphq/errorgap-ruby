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
        app.config.middleware.use Errorgap::RackMiddleware unless middleware_exists?(app)
      end

      def self.middleware_exists?(app)
        app.config.middleware.any? { |middleware| middleware.klass == Errorgap::RackMiddleware }
      end

      generators do
        require "generators/errorgap/install_generator"
      end
    end
  end
end
