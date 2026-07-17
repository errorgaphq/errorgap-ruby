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
      name: "User Load"
    )

    spans = Errorgap::SpanCollector.flush
    assert_equal 1, spans.size
    assert_equal "db", spans.first.kind
    assert_equal "SELECT * FROM users WHERE id = ?", spans.first.sql
  end

  # The sql.active_record payload has no :duration key — the duration must be
  # computed from the event's start/finish timestamps, or every query ships 0.
  def test_db_span_duration_comes_from_event_timing
    ActiveSupport::Notifications.instrument(
      "sql.active_record",
      sql: "SELECT * FROM users",
      name: "User Load"
    ) { sleep 0.02 }

    span = Errorgap::SpanCollector.flush.first
    assert_operator span.duration_ms, :>=, 15, "duration should reflect the instrumented block"
    assert_operator span.duration_ms, :<, 2_000
  end

  def test_db_span_captures_app_call_site
    ActiveSupport::Notifications.instrument(
      "sql.active_record",
      sql: "SELECT * FROM users",
      name: "User Load"
    )

    span = Errorgap::SpanCollector.flush.first
    refute_nil span.file, "the caller's file should be captured"
    assert span.file.end_with?("span_collector_install_test.rb"),
           "expected this test file as the app call site, got #{span.file.inspect}"
    assert_kind_of Integer, span.line
    # Ruby <= 3.3 labels the frame "test_...", 3.4+ "Class#test_...".
    assert_includes span.fn_name, "test_db_span_captures_app_call_site"
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
