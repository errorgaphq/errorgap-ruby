# frozen_string_literal: true

require "time"

module Errorgap
  # Delivers structured log lines to the ingestion API. Levels are ranked so a
  # configurable minimum threshold can drop low-severity logs before any
  # request is made.
  class LogDelivery
    LEVELS = %w[trace debug info warn error fatal].freeze
    LEVEL_ALIASES = { "warning" => "warn", "err" => "error", "critical" => "fatal", "panic" => "fatal" }.freeze

    def initialize(configuration)
      configure(configuration)
    end

    def configure(configuration)
      @configuration = configuration
    end

    def log(message, level: "info", source: nil, environment: nil, occurred_at: nil, sync: false)
      return unless @configuration.logs_enabled
      return if @configuration.ignored_environment?

      normalized = self.class.normalize_level(level)
      return if self.class.rank(normalized) < self.class.rank(self.class.normalize_level(@configuration.minimum_log_level))

      payload = {
        message: message.to_s,
        level: normalized,
        environment: environment || @configuration.environment,
        occurred_at: (occurred_at || Time.now).utc.iso8601(3)
      }
      payload[:source] = source.to_s if source

      if sync || !@configuration.async
        deliver(payload)
      else
        Errorgap.delivery.enqueue("logs", payload)
        nil
      end
    end

    def deliver(payload)
      Errorgap.delivery.post("logs", payload)
    end

    def self.normalize_level(level)
      value = level.to_s.strip.downcase
      value = LEVEL_ALIASES.fetch(value, value)
      LEVELS.include?(value) ? value : "info"
    end

    def self.rank(level)
      LEVELS.index(level) || LEVELS.index("info")
    end
  end
end
