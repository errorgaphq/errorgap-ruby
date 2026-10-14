# frozen_string_literal: true

module Errorgap
  module Integrations
    # Resque: report failed jobs with their class, queue and arguments.
    # Resque's own failure backend (the Failed tab) keeps working alongside.
    #
    #   Errorgap::Integrations::Resque.install   # after Resque is loaded
    module Resque
      class << self
        def install
          return false unless defined?(::Resque::Failure::Base)
          return true if @installed

          require "resque/failure/multiple"
          current = ::Resque::Failure.backend
          backends = current == ::Resque::Failure::Multiple ? ::Resque::Failure::Multiple.classes : [current]
          ::Resque::Failure::Multiple.classes = (backends + [backend]).uniq
          ::Resque::Failure.backend = ::Resque::Failure::Multiple
          @installed = true
        end

        # The failure backend, defined on first use so loading errorgap does
        # not need Resque.
        def backend
          @backend ||= Class.new(::Resque::Failure::Base) do
            def save
              job_class = payload.is_a?(Hash) ? payload["class"].to_s : ""
              Errorgap.notify_once(
                exception,
                context: { component: "resque", action: job_class },
                environment: { queue: queue.to_s },
                params: { "arguments" => payload.is_a?(Hash) ? payload["args"] : nil }
              )
            end

            def self.count(*)
              0
            end
          end
        end
      end
    end
  end
end
