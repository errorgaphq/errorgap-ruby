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
      # Call once at boot (from Railtie). Subscribers only record while a
      # transaction is being collected (the middleware starts one per request
      # when APM is enabled), so installing unconditionally is safe — and
      # required, since app initializers that enable APM run after railtie
      # initializers.
      def install
        return unless defined?(ActiveSupport::Notifications)
        return if @installed

        @installed = true

        # The 5-arg block form receives the event's start/finish times; the
        # sql.active_record payload itself carries no duration key.
        ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, started, finished, _id, payload|
          next unless Thread.current[THREAD_KEY]
          next if SKIP_NAMES.any? { |n| payload[:name]&.start_with?(n) }
          next if payload[:cached]

          duration_ms = ((finished - started) * 1000.0).to_f
          sql = normalize_sql(payload[:sql].to_s)
          file, line, fn_name = app_call_site

          store << Span.new(
            kind: "db", sql: sql,
            file: file, line: line, fn_name: fn_name,
            duration_ms: duration_ms.round(3)
          )
        end

        # Rails reports view_runtime with database time already subtracted, so
        # this does not double count the db spans above.
        ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*, payload|
          next unless Thread.current[THREAD_KEY]

          view_ms = payload[:view_runtime]
          next unless view_ms&.positive?

          store << Span.new(kind: "view", duration_ms: view_ms.round(3))
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

      # The first backtrace frame belonging to the application — skipping this
      # gem, other gems, and the Ruby standard library — so a query can be
      # attributed to the app code that ran it. Returns [file, line, fn_name]
      # with the file relative to Rails.root when available, or nils when no
      # app frame is present (e.g. queries run from a console or gem).
      def app_call_site
        root = defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : nil
        location = caller_locations(1, 60)&.find do |loc|
          path = loc.absolute_path || loc.path
          next false unless path
          next false if path.start_with?(LIB_ROOT)
          next false if GEM_PATH_MARKERS.any? { |marker| path.include?(marker) }

          root ? path.start_with?(root) : true
        end
        return [nil, nil, nil] unless location

        path = location.absolute_path || location.path
        path = path.delete_prefix("#{root}/") if root
        [path, location.lineno, location.label]
      end
    end

    LIB_ROOT = File.expand_path("..", __dir__)
    GEM_PATH_MARKERS = ["/gems/", "/rubygems/", "/lib/ruby/", "/bundler/"].freeze
  end
end
