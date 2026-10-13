# frozen_string_literal: true

require "test_helper"
require "socket"
require "rake"

class RemoteSettingsTest < Minitest::Test
  # Answers one GET with `body`, recording the request line and headers.
  def serve_once(body, status: 200)
    server = TCPServer.new("127.0.0.1", 0)
    seen = Queue.new
    thread = Thread.new do
      client = server.accept
      lines = []
      while (line = client.gets) && line != "\r\n"
        lines << line.strip
      end
      seen << lines
      client.write("HTTP/1.1 #{status} X\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      client.close
    end
    [server, seen, thread]
  end

  def config_for(port)
    config = Errorgap::Configuration.new
    config.project_slug = "demo"
    config.api_key = "key-demo"
    config.endpoint = "http://127.0.0.1:#{port}"
    config
  end

  def test_reads_the_projects_switches_with_the_project_key
    server, seen, thread = serve_once('{"errors_enabled":true,"apm_enabled":false,"logs_enabled":true,"poll_interval_seconds":600}')
    settings = Errorgap::RemoteSettings.new(config_for(server.addr[1]))
    settings.define_singleton_method(:ensure_polling) { nil }

    assert settings.enabled?(:apm), "everything is on until errorgap says otherwise"
    refute_nil settings.refresh
    refute settings.enabled?(:apm)
    assert settings.enabled?(:errors)
    assert settings.enabled?(:logs)

    request = seen.pop
    assert_equal "GET /api/projects/demo/config HTTP/1.1", request.first
    assert_includes request.map(&:downcase), "x-errorgap-project-key: key-demo"
  ensure
    thread&.join(1)
    server&.close
  end

  def test_everything_stays_on_when_errorgap_cannot_be_read_or_the_option_is_off
    server, _seen, thread = serve_once("nope", status: 500)
    settings = Errorgap::RemoteSettings.new(config_for(server.addr[1]))
    settings.define_singleton_method(:ensure_polling) { nil }
    assert_nil settings.refresh
    assert settings.enabled?(:errors)

    unreachable = config_for(1)
    assert_nil Errorgap::RemoteSettings.new(unreachable).refresh

    off = config_for(1)
    off.remote_settings = false
    assert Errorgap::RemoteSettings.new(off).enabled?(:errors)
  ensure
    thread&.join(1)
    server&.close
  end

  def test_a_switched_off_kind_is_not_sent
    Errorgap.configure do |config|
      config.project_slug = "demo"
      config.async = false
      config.logger = nil
    end
    Errorgap.remote_settings.define_singleton_method(:enabled?) { |kind| kind != :errors }
    response = Errorgap.notify(RuntimeError.new("boom"))

    assert_equal "errors are switched off for this project", response.body
  ensure
    Errorgap.remote_settings.singleton_class.send(:remove_method, :enabled?)
  end
end

class RakeIntegrationTest < Minitest::Test
  def test_a_failing_task_is_reported_with_its_name_and_reraised
    reported = []
    Errorgap.configure { |config| config.project_slug = "demo" }
    Errorgap.notifier.define_singleton_method(:notify) { |error, **options| reported << [error, options] }
    assert Errorgap::Integrations::Rake.install

    app = Rake::Application.new
    task = app.define_task(Rake::Task, "reports:nightly") { raise ArgumentError, "bad month" }
    error = assert_raises(ArgumentError) { task.invoke }

    assert_same error, reported.first[0]
    assert_equal({ component: "rake", action: "reports:nightly" }, reported.first[1][:context].slice(:component, :action))
  ensure
    Errorgap.notifier.singleton_class.send(:remove_method, :notify)
  end
end
