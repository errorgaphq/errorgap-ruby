# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Errorgap
  # The project's remote settings: what errorgap wants this app to send.
  # Someone can turn errors, performance data or logs off for a project in
  # errorgap (Project settings › What SDKs send) and running apps follow
  # within a poll interval, with no deploy.
  #
  # Read from `GET /api/projects/:slug/config` on a background thread, never
  # on the caller's. Until the first answer, and whenever errorgap cannot be
  # reached, everything stays on.
  class RemoteSettings
    DEFAULT_INTERVAL = 600
    MIN_INTERVAL = 60
    KINDS = { errors: "errors_enabled", apm: "apm_enabled", logs: "logs_enabled" }.freeze

    def initialize(configuration)
      @configuration = configuration
      @mutex = Mutex.new
      @settings = {}
      @interval = DEFAULT_INTERVAL
      @thread = nil
      @pid = nil
    end

    def configure(configuration)
      @configuration = configuration
    end

    # False only when errorgap has said to stop sending this kind of data.
    def enabled?(kind)
      return true unless @configuration.remote_settings

      ensure_polling
      @settings[KINDS.fetch(kind)] != false
    end

    # Fetch now, on this thread. Returns the settings, or nil when they
    # could not be read.
    def refresh
      uri = URI.join(base_url, "api/projects/#{@configuration.project_slug}/config")
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "errorgap-ruby/#{Errorgap::VERSION}"
      request["X-Errorgap-Project-Key"] = @configuration.api_key.to_s unless @configuration.api_key.to_s.empty?
      timeout = @configuration.timeout.to_f.positive? ? @configuration.timeout.to_f : 5
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                                                         open_timeout: timeout, read_timeout: timeout) do |http|
        http.request(request)
      end
      return nil unless response.code.to_i == 200

      apply(JSON.parse(response.body))
    rescue StandardError
      nil
    end

    private

    def apply(body)
      return nil unless body.is_a?(Hash)

      @settings = body.slice(*KINDS.values)
      seconds = body["poll_interval_seconds"].to_i
      @interval = seconds >= MIN_INTERVAL ? seconds : DEFAULT_INTERVAL
      @settings
    end

    # A forked child (Puma workers, Sidekiq) has the settings but not the
    # thread: start its own.
    def ensure_polling
      return if @pid == Process.pid && @thread&.alive?
      return if @configuration.project_slug.to_s.strip.empty?

      @mutex.synchronize do
        return if @pid == Process.pid && @thread&.alive?

        @pid = Process.pid
        @thread = Thread.new do
          loop do
            Thread.current[:errorgap_sending] = true
            refresh
            sleep(@interval)
          end
        end
        @thread.name = "errorgap-settings" if @thread.respond_to?(:name=)
        @thread.report_on_exception = false if @thread.respond_to?(:report_on_exception=)
      end
    end

    def base_url
      endpoint = @configuration.endpoint.to_s
      endpoint.end_with?("/") ? endpoint : "#{endpoint}/"
    end
  end
end
