# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Errorgap
  class Transacter
    def initialize(configuration)
      configure(configuration)
    end

    def configure(configuration)
      @configuration = configuration
    end

    def deliver_async(transaction)
      return if @configuration.ignored_environment?
      return unless should_sample?

      Thread.new { deliver(transaction) }
    end

    def deliver(transaction)
      uri = URI.join(
        @configuration.endpoint.end_with?("/") ? @configuration.endpoint : "#{@configuration.endpoint}/",
        "api/projects/#{@configuration.project_slug}/transactions"
      )
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "errorgap-ruby/#{Errorgap::VERSION}"
      request["X-Errorgap-Project-Key"] = @configuration.api_key if present?(@configuration.api_key)
      request.body = JSON.generate(transaction.to_h)

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end
    rescue StandardError => exception
      @configuration.logger&.warn("[errorgap] APM delivery error: #{exception.class}: #{exception.message}")
    end

    private

    def should_sample?
      rate = @configuration.apm_sample_rate.to_f
      return true if rate >= 1.0
      return false if rate <= 0.0

      rand < rate
    end

    def present?(value)
      !value.nil? && !value.to_s.empty?
    end
  end
end
