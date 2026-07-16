# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/notifications"

# Exercises the ActiveSupport::Notifications subscribers installed at boot.
# `install` is idempotent, so calling it in every test is safe.
class SpanCollectorInstallTest < Minitest::Test
  def setup
    Errorgap::SpanCollector.install
    Errorgap::SpanCollector.start
  end

  def teardown
    Errorgap::SpanCollector.flush
  end

  def test_records_db_span_from_sql_notification
    ActiveSupport::Notifications.instrument(
      "sql.active_record",
      sql: "SELECT * FROM users WHERE id = 42",
      name: "User Load",
      duration: 12.345
    )

    spans = Errorgap::SpanCollector.flush
    assert_equal 1, spans.size
    assert_equal "db", spans.first.kind
    assert_equal "SELECT * FROM users WHERE id = ?", spans.first.sql
  end

  def test_records_view_span_from_process_action_notification
    ActiveSupport::Notifications.instrument(
      "process_action.action_controller",
      view_runtime: 33.7,
      db_runtime: 10.0
    )

    spans = Errorgap::SpanCollector.flush
    assert_equal 1, spans.size
    assert_equal "view", spans.first.kind
    assert_in_delta 33.7, spans.first.duration_ms, 0.001
  end

  def test_skips_view_span_when_view_runtime_missing
    ActiveSupport::Notifications.instrument(
      "process_action.action_controller",
      view_runtime: nil
    )

    assert_empty Errorgap::SpanCollector.flush
  end

  def test_ignores_notifications_without_active_collection
    Errorgap::SpanCollector.flush

    ActiveSupport::Notifications.instrument(
      "sql.active_record",
      sql: "SELECT 1",
      name: "User Load",
      duration: 1.0
    )
    ActiveSupport::Notifications.instrument(
      "process_action.action_controller",
      view_runtime: 5.0
    )

    assert_nil Thread.current[Errorgap::SpanCollector::THREAD_KEY]
  end

  def test_skips_cached_and_schema_queries
    ActiveSupport::Notifications.instrument(
      "sql.active_record",
      sql: "SELECT 1",
      name: "SCHEMA",
      duration: 1.0
    )
    ActiveSupport::Notifications.instrument(
      "sql.active_record",
      sql: "SELECT 1",
      name: "User Load",
      cached: true,
      duration: 1.0
    )

    assert_empty Errorgap::SpanCollector.flush
  end
end
