# frozen_string_literal: true

module Errorgap
  class Transacter
    def initialize(configuration)
      configure(configuration)
    end

    def configure(configuration)
      @configuration = configuration
    end

    def deliver_async(transaction)
      return if @configuration.ignored_environment?
      return unless Errorgap.remote_settings.enabled?(:apm)
      return unless should_sample?

      Errorgap.delivery.enqueue("transactions", transaction.to_h)
    end

    def deliver(transaction)
      Errorgap.delivery.post("transactions", transaction.to_h)
    end

    private

    def should_sample?
      rate = @configuration.apm_sample_rate.to_f
      return true if rate >= 1.0
      return false if rate <= 0.0

      rand < rate
    end
  end
end
