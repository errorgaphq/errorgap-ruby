# frozen_string_literal: true

require "test_helper"
require "socket"
require "tmpdir"
require "fileutils"

# A one-thread HTTP server that answers each request with the next scripted
# [status, headers] pair and records the request bodies.
class StubServer
  attr_reader :port, :requests

  def initialize(responses)
    @responses = responses
    @requests = []
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve }
  end

  def close
    @thread.kill
    @server.close
  end

  private

  def serve
    loop do
      client = @server.accept
      request_line = client.gets.to_s
      length = 0
      while (line = client.gets) && line != "\r\n"
        length = line.split(":", 2).last.to_i if line.downcase.start_with?("content-length")
      end
      body = length.positive? ? client.read(length) : ""
      @requests << [request_line.split(" ")[1], body]
      status, headers = @responses.length > 1 ? @responses.shift : @responses.first
      head = (headers || {}).map { |key, value| "#{key}: #{value}\r\n" }.join
      client.write("HTTP/1.1 #{status} X\r\nContent-Length: 2\r\nConnection: close\r\n#{head}\r\n{}")
      client.close
    end
  rescue IOError, Errno::EBADF
    nil
  end
end

class DeliveryTest < Minitest::Test
  def config_for(server)
    config = Errorgap::Configuration.new
    config.project_slug = "demo"
    config.endpoint = "http://127.0.0.1:#{server.port}"
    config.logger = nil
    config
  end

  def test_queued_payloads_are_sent_in_order_by_one_worker
    server = StubServer.new([[201, {}]])
    delivery = Errorgap::Delivery.new(config_for(server))
    3.times { |n| delivery.enqueue("notices", { n: n }) }
    delivery.flush

    assert_equal %w[{"n":0} {"n":1} {"n":2}], server.requests.map(&:last)
    assert_equal "/api/projects/demo/notices", server.requests.first.first
  ensure
    server.close
  end

  def test_a_429_pauses_sending_for_retry_after
    server = StubServer.new([[429, { "Retry-After" => "120" }]])
    delivery = Errorgap::Delivery.new(config_for(server))

    assert_equal 429, delivery.post("notices", {}).status
    assert delivery.paused?
    blocked = delivery.post("notices", {})
    assert_kind_of Errorgap::Delivery::RateLimited, blocked.error
    assert_equal 1, server.requests.length
  ensure
    server.close
  end

  def test_a_server_error_is_retried_and_a_client_error_is_not
    delivery = Errorgap::Delivery.new(Errorgap::Configuration.new)
    result = Errorgap::Delivery::Result

    assert delivery.send(:retryable?, result.new(status: 500))
    assert delivery.send(:retryable?, result.new(error: Errno::ECONNREFUSED.new))
    refute delivery.send(:retryable?, result.new(status: 422))
    refute delivery.send(:retryable?, result.new(status: 429))
    refute delivery.send(:retryable?, result.new(error: Errorgap::Delivery::RateLimited.new))
  end

  def test_a_failed_send_waits_in_the_backlog_up_to_three_attempts
    delivery = Errorgap::Delivery.new(Errorgap::Configuration.new)
    item = Errorgap::Delivery::Item.new("notices", {}, 1, nil)
    delivery.send(:retry_later, item)
    backlog = delivery.instance_variable_get(:@backlog)

    assert_equal 2, backlog.first.attempt
    delivery.send(:retry_later, Errorgap::Delivery::Item.new("notices", {}, 3, nil))
    assert_equal 1, backlog.length
  end

  def test_a_full_queue_drops_the_oldest_payload
    config = Errorgap::Configuration.new
    config.project_slug = "demo"
    config.queue_size = 2
    config.logger = nil
    delivery = Errorgap::Delivery.new(config)
    # Hold the worker so nothing leaves the queue.
    delivery.define_singleton_method(:ensure_worker) { nil }
    3.times { |n| delivery.enqueue("notices", { n: n }) }

    assert_equal [1, 2], delivery.instance_variable_get(:@queue).map { |item| item.payload[:n] }
  end
end

class SanitizerTest < Minitest::Test
  def test_masks_sensitive_keys_at_any_depth
    filtered = Errorgap::Sanitizer.new(["password", /\Assn\z/]).filter(
      user: { password: "x", profile: [{ "api_password" => "y", ssn: "z", name: "Ada" }] }
    )

    assert_equal "[FILTERED]", filtered["user"]["password"]
    assert_equal "[FILTERED]", filtered["user"]["profile"][0]["api_password"]
    assert_equal "[FILTERED]", filtered["user"]["profile"][0]["ssn"]
    assert_equal "Ada", filtered["user"]["profile"][0]["name"]
  end

  def test_survives_cycles_binary_and_oversized_values
    loop_hash = { "name" => "a" }
    loop_hash["self"] = loop_hash
    cleaned = Errorgap::Sanitizer.new.clean(
      "loop" => loop_hash, "binary" => "\xFF\xFE".b, "long" => "x" * 10_000, "many" => (1..500).to_a
    )

    assert_equal "[CIRCULAR]", cleaned["loop"]["self"]
    assert cleaned["binary"].valid_encoding?
    assert cleaned["long"].end_with?("[TRUNCATED]")
    assert_equal 128, cleaned["many"].length
    assert JSON.generate(cleaned)
  end
end

class BeforeNotifyTest < Minitest::Test
  def notifier_with
    config = Errorgap::Configuration.new
    config.project_slug = "demo"
    config.async = false
    yield config
    notifier = Errorgap::Notifier.new(config)
    sent = []
    notifier.define_singleton_method(:deliver) do |payload|
      sent << payload
      Errorgap::Notifier::Response.new(status: 201)
    end
    [notifier, sent]
  end

  def test_a_hook_can_drop_a_notice
    notifier, sent = notifier_with do |config|
      config.before_notify { |notice| false if notice[:errors][0][:type] == "ArgumentError" }
    end

    assert_equal "dropped by before_notify", notifier.notify(ArgumentError.new("no")).body
    notifier.notify(RuntimeError.new("yes"))
    assert_equal ["RuntimeError"], sent.map { |notice| notice[:errors][0][:type] }
  end

  def test_a_hook_can_change_a_notice_and_a_raising_hook_is_skipped
    notifier, sent = notifier_with do |config|
      config.logger = nil
      config.before_notify { |_notice| raise "bug in the hook" }
      config.before_notify { |notice| notice[:context]["team"] = "billing" }
    end

    notifier.notify(RuntimeError.new("boom"))
    assert_equal "billing", sent.first[:context]["team"]
  end
end

class ReleaseDetectorTest < Minitest::Test
  def test_reads_the_platform_variable_then_revision_file_then_git_head
    Dir.mktmpdir do |root|
      assert_nil Errorgap::ReleaseDetector.detect(root, {})

      FileUtils.mkdir_p(File.join(root, ".git", "refs", "heads"))
      File.write(File.join(root, ".git", "HEAD"), "ref: refs/heads/main\n")
      File.write(File.join(root, ".git", "refs", "heads", "main"), "#{'a' * 40}\n")
      assert_equal "a" * 40, Errorgap::ReleaseDetector.detect(root, {})

      File.delete(File.join(root, ".git", "refs", "heads", "main"))
      File.write(File.join(root, ".git", "packed-refs"), "# pack-refs\n#{'b' * 40} refs/heads/main\n")
      assert_equal "b" * 40, Errorgap::ReleaseDetector.detect(root, {})

      File.write(File.join(root, "REVISION"), "cap123\n")
      assert_equal "cap123", Errorgap::ReleaseDetector.detect(root, {})
      assert_equal "env456", Errorgap::ReleaseDetector.detect(root, { "SOURCE_VERSION" => "env456" })
    end
  end
end

class IntegrationsTest < Minitest::Test
  def setup
    @notices = notices = []
    @jobs = jobs = []
    Errorgap.configure do |config|
      config.project_slug = "demo"
      config.apm_enabled = true
      config.async = false
    end
    Errorgap.notifier.define_singleton_method(:notify) { |error, **options| notices << [error, options] }
    Errorgap.transacter.define_singleton_method(:deliver) { |txn| jobs << txn.to_h }
  end

  def teardown
    Errorgap.notifier.singleton_class.send(:remove_method, :notify)
    Errorgap.transacter.singleton_class.send(:remove_method, :deliver)
    Errorgap.configure { |config| config.apm_enabled = false }
    Errorgap.clear_user
  end

  def test_sidekiq_middleware_reports_and_reraises_and_times_the_job
    job = { "class" => "ReceiptJob", "jid" => "j1", "args" => [7, { "token" => "t" }] }
    error = assert_raises(RuntimeError) do
      Errorgap::Integrations::Sidekiq.new.call(nil, job, "mailers") { raise "smtp down" }
    end

    reported, options = @notices.first
    assert_same error, reported
    assert_equal "ReceiptJob", options[:context][:action]
    assert_equal [7, { "token" => "t" }], options[:params]["arguments"]
    assert_equal "j1", options[:environment][:job_id]
    assert_equal @jobs.first[:id], options[:context][:transaction_id]
    assert_equal %w[job ReceiptJob mailers], @jobs.first.values_at(:kind, :job_class, :queue)
  end

  def test_an_error_is_reported_once_however_many_layers_see_it
    error = RuntimeError.new("once")
    Errorgap.notify_once(error)
    Errorgap.notify_once(error)

    assert_equal 1, @notices.length
  end

  def test_set_user_names_the_user_on_notices_from_this_thread
    Errorgap.set_user(id: 42, email: "ada@example.com")
    Errorgap.notify(RuntimeError.new("boom"), session: { "cart" => 1 })

    assert_equal({ "user_id" => "42", "user_email" => "ada@example.com", "cart" => 1 }, @notices.first[1][:session])
  end

  def test_rack_middleware_filters_the_query_string_and_names_the_warden_user
    user = Struct.new(:id, :email).new(9, "sam@example.com")
    warden = Struct.new(:user) do
      def authenticated?
        true
      end
    end.new(user)
    env = {
      "REQUEST_METHOD" => "GET", "PATH_INFO" => "/orders", "QUERY_STRING" => "page=2&access_token=abc",
      "rack.url_scheme" => "http", "HTTP_HOST" => "x.test", "warden" => warden
    }
    Errorgap.configure { |config| config.apm_enabled = false }
    assert_raises(RuntimeError) { Errorgap::RackMiddleware.new(->(_env) { raise "boom" }).call(env) }

    options = @notices.first[1]
    assert_equal "page=2&access_token=[FILTERED]", options[:environment][:query_string]
    assert_equal "9", options[:session]["user_id"]
    assert_equal "sam@example.com", options[:session]["user_email"]
  end
end
