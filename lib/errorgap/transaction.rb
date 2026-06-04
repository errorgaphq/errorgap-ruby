# frozen_string_literal: true

require "time"

module Errorgap
  Span = Struct.new(:kind, :sql, :file, :line, :fn_name, :duration_ms, keyword_init: true) do
    def to_h
      {
        kind: kind,
        sql: sql,
        file: file,
        line: line,
        fn_name: fn_name,
        duration_ms: duration_ms
      }.compact
    end
  end

  Transaction = Struct.new(
    :kind, :method, :path, :path_raw, :status_code,
    :duration_ms, :environment, :occurred_at, :spans,
    :job_class, :queue,
    keyword_init: true
  ) do
    def to_h
      {
        kind: kind,
        method: method,
        path: path,
        path_raw: path_raw,
        status_code: status_code,
        duration_ms: duration_ms,
        environment: environment,
        occurred_at: occurred_at&.utc&.iso8601(3),
        spans: Array(spans).map(&:to_h),
        job_class: job_class,
        queue: queue
      }.compact
    end
  end
end
