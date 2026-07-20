# frozen_string_literal: true

module Errorgap
  # Yielded to `Errorgap.track_transaction` / `track_job` blocks so callers can
  # record spans manually (outside Rails' automatic `sql.active_record`
  # instrumentation) — e.g. outbound HTTP calls or queries in a plain Ruby
  # service. Spans are appended to the same thread-local store the automatic
  # collector uses, so manual and automatic spans merge into one transaction.
  class SpanRecorder
    def database(sql, duration_ms, file: nil, line: nil, fn_name: nil)
      SpanCollector.store << Span.new(
        kind: "db",
        sql: SpanCollector.normalize_sql(sql.to_s),
        file: file, line: line, fn_name: fn_name,
        duration_ms: duration_ms.to_f.round(3)
      )
    end

    def external(duration_ms, file: nil, line: nil, fn_name: nil)
      SpanCollector.store << Span.new(
        kind: "http",
        file: file, line: line, fn_name: fn_name,
        duration_ms: duration_ms.to_f.round(3)
      )
    end

    def add(span)
      SpanCollector.store << span
    end
  end
end
