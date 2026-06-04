# frozen_string_literal: true

require "test_helper"

class TransactionTest < Minitest::Test
  def test_span_to_h_omits_nil_fields
    span = Errorgap::Span.new(kind: "db", sql: "SELECT ?", duration_ms: 12.5)
    h = span.to_h

    assert_equal "db", h[:kind]
    assert_equal "SELECT ?", h[:sql]
    assert_equal 12.5, h[:duration_ms]
    refute h.key?(:file)
    refute h.key?(:line)
    refute h.key?(:fn_name)
  end

  def test_transaction_to_h_serialises_all_fields
    span = Errorgap::Span.new(kind: "view", duration_ms: 8.0)
    occurred = Time.utc(2026, 6, 4, 12, 0, 0)

    txn = Errorgap::Transaction.new(
      kind: "web",
      method: "GET",
      path: "projects#show",
      path_raw: "/projects/1",
      status_code: 200,
      duration_ms: 130.5,
      environment: "production",
      occurred_at: occurred,
      spans: [span]
    )

    h = txn.to_h

    assert_equal "web",           h[:kind]
    assert_equal "GET",           h[:method]
    assert_equal "projects#show", h[:path]
    assert_equal "/projects/1",   h[:path_raw]
    assert_equal 200,             h[:status_code]
    assert_equal 130.5,           h[:duration_ms]
    assert_equal "production",    h[:environment]
    assert_equal "2026-06-04T12:00:00.000Z", h[:occurred_at]
    assert_equal 1,               h[:spans].length
    assert_equal "view",          h[:spans].first[:kind]
  end

  def test_transaction_to_h_omits_nil_optional_fields
    txn = Errorgap::Transaction.new(
      kind: "web",
      method: "GET",
      path: "home#index",
      duration_ms: 50.0,
      environment: "test",
      occurred_at: Time.now,
      spans: []
    )

    h = txn.to_h

    refute h.key?(:job_class)
    refute h.key?(:queue)
    refute h.key?(:path_raw)
    refute h.key?(:status_code)
  end

  def test_job_transaction_includes_job_fields
    txn = Errorgap::Transaction.new(
      kind: "job",
      job_class: "SearchIndexJob",
      queue: "critical",
      duration_ms: 340.0,
      environment: "production",
      occurred_at: Time.now,
      spans: []
    )

    h = txn.to_h

    assert_equal "job",            h[:kind]
    assert_equal "SearchIndexJob", h[:job_class]
    assert_equal "critical",       h[:queue]
  end
end
