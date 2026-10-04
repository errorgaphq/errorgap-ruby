# frozen_string_literal: true

require "test_helper"

# Errors raised inside an APM transaction carry its id, so errorgap shows the
# error the request actually raised and links the occurrence to its trace.
class TransactionIdTest < Minitest::Test
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  class << self
    def transactions
      @transactions ||= []
    end

    def notices
      @notices ||= []
    end
  end

  def setup
    Errorgap.configure do |config|
      config.project_slug = "demo"
      config.environment = "production"
      config.async = false
      config.apm_enabled = true
      config.apm_sample_rate = 1.0
    end
    self.class.transactions.clear
    self.class.notices.clear
    Errorgap.transacter.define_singleton_method(:deliver) { |txn| TransactionIdTest.transactions << txn.to_h }
    Errorgap.transacter.define_singleton_method(:deliver_async) { |txn| TransactionIdTest.transactions << txn.to_h }
    Errorgap.notifier.define_singleton_method(:notify) { |_error, **kw| TransactionIdTest.notices << kw }
  end

  def teardown
    Errorgap.transacter.singleton_class.send(:remove_method, :deliver)
    Errorgap.transacter.singleton_class.send(:remove_method, :deliver_async)
    Errorgap.notifier.singleton_class.send(:remove_method, :notify)
  end

  def test_a_notice_inside_a_transaction_carries_its_id
    Errorgap.track_transaction(method: "GET", path: "/orders/{id}", status_code: 500, sync: true) do
      Errorgap.notify(RuntimeError.new("boom"))
    end

    transaction_id = self.class.transactions.first[:id]
    assert_match UUID, transaction_id
    assert_equal transaction_id, self.class.notices.first[:context][:transaction_id]
    assert_nil Errorgap.current_transaction_id, "the id does not outlive its transaction"
  end

  def test_jobs_get_their_own_id
    Errorgap.track_job("ReceiptJob", sync: true) { Errorgap.notify(RuntimeError.new("job failed")) }
    job_id = self.class.transactions.first[:id]
    assert_match UUID, job_id
    assert_equal job_id, self.class.notices.first[:context][:transaction_id]
  end

  def test_no_transaction_no_id
    Errorgap.notify(RuntimeError.new("at boot"))
    refute self.class.notices.first[:context].key?(:transaction_id)
  end

  def test_an_explicit_transaction_id_is_kept
    Errorgap.track_transaction(sync: true) do
      Errorgap.notify(RuntimeError.new("x"), context: { transaction_id: "mine" })
    end
    assert_equal "mine", self.class.notices.first[:context][:transaction_id]
  end

  def test_the_rack_middleware_links_the_request_and_its_error
    app = ->(_env) { raise ArgumentError, "bad request" }
    middleware = Errorgap::RackMiddleware.new(app)
    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/orders/7", "rack.url_scheme" => "https", "HTTP_HOST" => "shop" }
    assert_raises(ArgumentError) { middleware.call(env) }

    transaction = self.class.transactions.first
    assert_match UUID, transaction[:id]
    assert_equal 500, transaction[:status_code]
    assert_equal transaction[:id], self.class.notices.first[:context][:transaction_id]
  end

  def test_concurrent_requests_never_share_an_id
    ids = 2.times.map do
      Thread.new { Errorgap.with_transaction_id { |id| sleep 0.01; [id, Errorgap.current_transaction_id] } }
    end.map(&:value)
    ids.each { |given, seen| assert_equal given, seen }
    refute_equal ids[0][0], ids[1][0]
  end
end

class ReleaseAndTraceTest < Minitest::Test
  def test_release_comes_from_the_environment
    previous = ENV["ERRORGAP_RELEASE"]
    ENV["ERRORGAP_RELEASE"] = " abc123 "
    assert_equal "abc123", Errorgap::Configuration.new.release
    ENV.delete("ERRORGAP_RELEASE")
    assert_nil Errorgap::Configuration.new.release
  ensure
    previous ? ENV["ERRORGAP_RELEASE"] = previous : ENV.delete("ERRORGAP_RELEASE")
  end

  def test_notices_carry_the_release
    config = Errorgap::Configuration.new
    config.project_slug = "demo"
    config.release = "abc123"
    notice = Errorgap::Notice.from_exception(RuntimeError.new("x"), configuration: config)
    assert_equal "abc123", notice.to_h[:context][:release]
  end
end

class TransactionIdTest
  def test_the_middleware_records_the_browser_trace_header
    middleware = Errorgap::RackMiddleware.new(->(_env) { [200, {}, ["ok"]] })
    trace = "0192F3C4-7A1B-4C2D-9E3F-0123456789AB"
    middleware.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/orders/7", "HTTP_X_ERRORGAP_TRACE" => trace)
    middleware.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/orders/8", "HTTP_X_ERRORGAP_TRACE" => "not-a-uuid")

    assert_equal trace.downcase, self.class.transactions[0][:trace_id]
    refute self.class.transactions[1].key?(:trace_id), "a malformed header is ignored"
    refute_equal self.class.transactions[0][:id], self.class.transactions[0][:trace_id]
  end
end
