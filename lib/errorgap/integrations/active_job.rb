# frozen_string_literal: true

module Errorgap
  module Integrations
    # ActiveJob, whatever the queue adapter: every job runs as a `job`
    # transaction and an error it raises is reported with the job's class,
    # queue, id and arguments, then re-raised so `retry_on` / `discard_on` and
    # the adapter's own retries work as before. The Rails railtie installs it.
    module ActiveJob
      class << self
        def install
          return false unless defined?(::ActiveSupport) && ::ActiveSupport.respond_to?(:on_load)
          return true if @installed

          ::ActiveSupport.on_load(:active_job) do
            around_perform { |job, block| Errorgap::Integrations::ActiveJob.perform(job, &block) }
          end
          @installed = true
        end

        def installed?
          @installed == true
        end

        def perform(job, &block)
          Errorgap.track_job(job.class.name.to_s, queue: job.queue_name.to_s) do
            run(job, &block)
          end
        ensure
          Errorgap.clear_user
        end

        private

        def run(job)
          yield
        rescue Exception => exception # rubocop:disable Lint/RescueException
          Errorgap.notify_once(
            exception,
            context: { component: "active_job", action: job.class.name.to_s },
            environment: { queue: job.queue_name.to_s, job_id: job.job_id, executions: job.executions }.compact,
            params: { "arguments" => arguments(job) }
          )
          raise
        end

        # Records and other GlobalID arguments are named, not serialized.
        def arguments(job)
          Array(job.arguments).map do |argument|
            argument.respond_to?(:to_global_id) ? argument.to_global_id.to_s : argument
          end
        rescue StandardError
          []
        end
      end
    end
  end
end
