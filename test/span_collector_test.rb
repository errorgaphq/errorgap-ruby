# frozen_string_literal: true

require "test_helper"

class SpanCollectorTest < Minitest::Test
  def test_normalizes_quoted_strings
    sql = "SELECT * FROM users WHERE email = 'user@example.com'"
    assert_equal "SELECT * FROM users WHERE email = ?",
                 Errorgap::SpanCollector.normalize_sql(sql)
  end

  def test_normalizes_integer_literals
    sql = "SELECT * FROM orders WHERE id = 42 AND status = 1"
    assert_equal "SELECT * FROM orders WHERE id = ? AND status = ?",
                 Errorgap::SpanCollector.normalize_sql(sql)
  end

  def test_normalizes_float_literals
    sql = "SELECT * FROM metrics WHERE value > 0.95"
    assert_equal "SELECT * FROM metrics WHERE value > ?",
                 Errorgap::SpanCollector.normalize_sql(sql)
  end

  def test_normalizes_multiple_string_params
    sql = "INSERT INTO sessions (token, ip) VALUES ('abc123', '127.0.0.1')"
    assert_equal "INSERT INTO sessions (token, ip) VALUES (?, ?)",
                 Errorgap::SpanCollector.normalize_sql(sql)
  end

  def test_collapses_whitespace
    sql = "SELECT  *  FROM   users  WHERE  id = 1"
    assert_equal "SELECT * FROM users WHERE id = ?",
                 Errorgap::SpanCollector.normalize_sql(sql)
  end

  def test_thread_local_isolation
    Errorgap::SpanCollector.start
    Errorgap::SpanCollector.store << Errorgap::Span.new(kind: "db", duration_ms: 1.0)
    spans = Errorgap::SpanCollector.flush

    assert_equal 1, spans.length
    assert_nil Thread.current[Errorgap::SpanCollector::THREAD_KEY]
  end

  def test_flush_returns_empty_when_not_started
    Thread.current[Errorgap::SpanCollector::THREAD_KEY] = nil
    assert_equal [], Errorgap::SpanCollector.flush
  end
end
