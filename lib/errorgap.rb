# frozen_string_literal: true

require_relative "errorgap/configuration"
require_relative "errorgap/notifier"
require_relative "errorgap/notice"
require_relative "errorgap/rack_middleware"
require_relative "errorgap/version"

module Errorgap
  class << self
    def configure
      yield(configuration)
      notifier.configure(configuration)
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def notifier
      @notifier ||= Notifier.new(configuration)
    end

    def notify(error, context: {}, environment: {}, session: {}, params: {}, sync: false)
      notifier.notify(
        error,
        context: context,
        environment: environment,
        session: session,
        params: params,
        sync: sync
      )
    end
  end
end

require_relative "errorgap/rails/railtie" if defined?(Rails::Railtie)
