# frozen_string_literal: true

module Errorgap
  module Integrations
    # Times outbound `Net::HTTP` requests made during a transaction and
    # records each as an `http` span named by method and host. Most Ruby HTTP
    # clients (Faraday's default adapter, HTTParty, RestClient) use Net::HTTP
    # underneath. Requests errorgap makes itself are left out.
    module NetHTTP
      class << self
        def install
          return false unless defined?(::Net::HTTP)
          return true if @installed

          ::Net::HTTP.prepend(Patch)
          @installed = true
        end
      end

      module Patch
        def request(req, body = nil, &block)
          # `request` calls itself once when the connection is not started.
          unless started? && Thread.current[SpanCollector::THREAD_KEY] && !Errorgap::Delivery.sending?
            return super
          end

          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            super
          ensure
            elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0
            Errorgap::Integrations::NetHTTP.record(req, address, elapsed_ms)
          end
        end
      end

      def self.record(request, host, elapsed_ms)
        file, line, = SpanCollector.app_call_site
        SpanCollector.store << Span.new(
          kind: "http",
          fn_name: "#{request.method} #{host}",
          file: file, line: line,
          duration_ms: elapsed_ms.round(3)
        )
      rescue StandardError
        nil
      end
    end
  end
end
