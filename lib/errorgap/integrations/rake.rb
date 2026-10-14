# frozen_string_literal: true

module Errorgap
  module Integrations
    # Rake: report an error that ends a task, with the task's name, then
    # re-raise it. The report is flushed before Rake exits.
    #
    #   require "errorgap"
    #   Errorgap::Integrations::Rake.install   # in the Rakefile
    #
    # In Rails this is installed for you.
    module Rake
      class << self
        def install
          return false unless defined?(::Rake::Task)
          return true if @installed

          ::Rake::Task.prepend(Patch)
          @installed = true
        end
      end

      module Patch
        def execute(args = nil)
          super
        rescue SystemExit, Interrupt
          raise
        rescue Exception => exception # rubocop:disable Lint/RescueException
          begin
            Errorgap.notify_once(
              exception,
              context: { component: "rake", action: name.to_s },
              params: { "arguments" => args.respond_to?(:to_a) ? args.to_a : nil }
            )
            Errorgap.flush
          rescue StandardError
            nil
          end
          raise
        end
      end
    end
  end
end
