# frozen_string_literal: true

require "test_helper"

class ApmPublicTest < Minitest::Test
  def setup
    Errorgap.configure do |config|
      config.project_slug = "demo"
      config.environment = "production"
      config.async = false
      config.apm_enabled = true
      config.apm_sample_rate = 1.0
    end
    @delivered = []
    Errorgap.transacter.define_singleton_method(:deliver) { |txn| ApmPublicTest.captured << txn }
    ApmPublicTest.captured.clear
  end

  class << self
    def captured
      @captured ||= []
    end
  end

  def test_track_transaction_builds_web_transaction_with_manual_spans
    Errorgap.track_transaction(method: "GET", path: "/orders/{id}", path_raw: "/orders/7", status_code: 200, sync: true) do |spans|
      spans.database("SELECT * FROM orders WHERE id = 7", 4.2, fn_name: "Repo.load")
      spans.external(30.0, fn_name: "Gateway.fetch")
    end

    txn = ApmPublicTest.captured.first.to_h
    assert_equal "web", txn[:kind]
    assert_equal "/orders/{id}", txn[:path]
    assert_equal 200, txn[:status_code]
    kinds = txn[:spans].map { |s| s[:kind] }
    assert_equal %w[db http], kinds
    assert_equal "SELECT * FROM orders WHERE id = ?", txn[:spans].first[:sql]
  end

  def test_track_job_builds_job_transaction
    Errorgap.track_job("ReceiptJob", queue: "mailers", sync: true) do |spans|
      spans.database("SELECT 1", 1.0)
    end

    txn = ApmPublicTest.captured.first.to_h
    assert_equal "job", txn[:kind]
    assert_equal "ReceiptJob", txn[:job_class]
    assert_equal "mailers", txn[:queue]
    assert_equal 1, txn[:spans].length
  end

  def test_notify_transaction_skips_when_apm_disabled
    Errorgap.configuration.apm_enabled = false
    Errorgap.notify_transaction(Errorgap::Transaction.new(kind: "web", duration_ms: 5), sync: true)
    assert_empty ApmPublicTest.captured
  end
end
