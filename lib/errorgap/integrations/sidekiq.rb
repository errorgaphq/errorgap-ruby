# frozen_string_literal: true

module Errorgap
  module Integrations
    # Sidekiq server middleware: every job runs as a `job` transaction and an
    # error it raises is reported with the job's class, queue, id and
    # arguments, then re-raised so Sidekiq's retries work as before.
    #
    # Installed automatically when Sidekiq is loaded before errorgap is
    # configured; otherwise:
    #
    #   Sidekiq.configure_server do |config|
    #     config.server_middleware { |chain| chain.add Errorgap::Integrations::Sidekiq }
    #   end
    class Sidekiq
      class << self
        def install
          return false unless defined?(::Sidekiq) && ::Sidekiq.respond_to?(:configure_server)
          return true if @installed

          ::Sidekiq.configure_server do |config|
            config.server_middleware { |chain| chain.add Errorgap::Integrations::Sidekiq }
          end
          @installed = true
        end
      end

      def call(_worker, job, queue, &block)
        # An ActiveJob run by Sidekiq is covered by the ActiveJob integration,
        # which knows the real job class and its arguments.
        return yield if job["wrapped"] && Errorgap::Integrations::ActiveJob.installed?

        job_class = (job["wrapped"] || job["class"]).to_s
        Errorgap.track_job(job_class, queue: queue.to_s) do
          run(job, job_class, queue, &block)
        end
      ensure
        Errorgap.clear_user
      end

      private

      def run(job, job_class, queue)
        yield
      rescue Exception => exception # rubocop:disable Lint/RescueException
        Errorgap.notify_once(
          exception,
          context: { component: "sidekiq", action: job_class },
          environment: { queue: queue.to_s, job_id: job["jid"], retry_count: job["retry_count"] }.compact,
          params: { "arguments" => job["args"] }
        )
        raise
      end
    end
  end
end
