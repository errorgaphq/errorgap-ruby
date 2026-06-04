# frozen_string_literal: true

module Errorgap
  class SpanCollector
    THREAD_KEY = :errorgap_spans

    # Quoted strings and standalone numeric literals → ?
    NORMALIZE_PATTERN = /
      '(?:[^'\\]|\\.)*'   # single-quoted string literals
      |
      \b\d+(?:\.\d+)?\b   # integer and float literals
    /x

    SKIP_NAMES = %w[SCHEMA EXPLAIN CACHE].freeze

    class << self
      # Call once at boot (from Railtie) when APM is enabled.
      def install
        return unless defined?(ActiveSupport::Notifications)

        ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          next unless Thread.current[THREAD_KEY]
          next if SKIP_NAMES.any? { |n| payload[:name]&.start_with?(n) }
          next if payload[:cached]

          duration_ms = payload[:duration] || 0.0
          sql = normalize_sql(payload[:sql].to_s)

          store << Span.new(kind: "db", sql: sql, duration_ms: duration_ms.round(3))
        end
      end

      def start
        Thread.current[THREAD_KEY] = []
      end

      def flush
        spans = Thread.current[THREAD_KEY] || []
        Thread.current[THREAD_KEY] = nil
        spans
      end

      def store
        Thread.current[THREAD_KEY] ||= []
      end

      def normalize_sql(sql)
        sql.gsub(NORMALIZE_PATTERN, "?").gsub(/\s+/, " ").strip
      end
    end
  end
end
