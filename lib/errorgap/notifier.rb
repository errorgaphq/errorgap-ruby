# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Errorgap
  class Notifier
    Response = Struct.new(:status, :body, :error, keyword_init: true) do
      def success?
        error.nil? && status.to_i.between?(200, 299)
      end
    end

    def initialize(configuration)
      configure(configuration)
    end

    def configure(configuration)
      @configuration = configuration
    end

    def notify(error, context: {}, environment: {}, session: {}, params: {}, sync: false)
      @configuration.validate!
      return Response.new(status: 202, body: "ignored environment") if @configuration.ignored_environment?

      notice = Notice.from_exception(
        error,
        configuration: @configuration,
        context: context,
        environment: environment,
        session: session,
        params: params
      )

      if sync || !@configuration.async
        deliver(notice)
      else
        Thread.new { deliver(notice) }
        Response.new(status: 202, body: "queued")
      end
    rescue StandardError => exception
      log(exception)
      Response.new(error: exception)
    end

    def deliver(notice)
      uri = URI.join(@configuration.endpoint.end_with?("/") ? @configuration.endpoint : "#{@configuration.endpoint}/", "api/projects/#{@configuration.project_slug}/notices")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "errorgap-ruby/#{Errorgap::VERSION}"
      request["X-Errorgap-Project-Key"] = @configuration.api_key if present?(@configuration.api_key)
      request.body = JSON.generate(notice.to_h)

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end
      Response.new(status: response.code.to_i, body: response.body)
    rescue StandardError => exception
      log(exception)
      Response.new(error: exception)
    end

    private

    def log(exception)
      @configuration.logger&.warn("[errorgap] #{exception.class}: #{exception.message}")
    end

    def present?(value)
      !value.nil? && !value.to_s.empty?
    end
  end
end
