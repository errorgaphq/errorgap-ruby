# frozen_string_literal: true

module Errorgap
  module Integrations
    # Delayed Job: every job runs as a `job` transaction and an error it
    # raises is reported with the job's class, queue, id and attempt count,
    # then re-raised so Delayed Job's retries work as before.
    #
    #   Errorgap::Integrations::DelayedJob.install   # after Delayed Job is loaded
    module DelayedJob
      ACTIVE_JOB_WRAPPER = "ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper"

      class << self
        def install
          return false unless defined?(::Delayed::Plugin) && defined?(::Delayed::Worker)
          return true if @installed

          ::Delayed::Worker.plugins << plugin
          @installed = true
        end

        def plugin
          @plugin ||= Class.new(::Delayed::Plugin) do
            callbacks do |lifecycle|
              lifecycle.around(:invoke_job) do |job, *args, &block|
                Errorgap::Integrations::DelayedJob.invoke(job) { block.call(job, *args) }
              end
            end
          end
        end

        def invoke(job, &block)
          job_class = job_name(job)
          # An ActiveJob run by Delayed Job is covered by the ActiveJob
          # integration, which knows the real job class and its arguments.
          return yield if job_class == ACTIVE_JOB_WRAPPER && ActiveJob.installed?

          Errorgap.track_job(job_class, queue: (job.respond_to?(:queue) && job.queue) || "default") do
            run(job, job_class, &block)
          end
        ensure
          Errorgap.clear_user
        end

        private

        def run(job, job_class)
          yield
        rescue Exception => exception # rubocop:disable Lint/RescueException
          Errorgap.notify_once(
            exception,
            context: { component: "delayed_job", action: job_class },
            environment: {
              queue: job.respond_to?(:queue) ? job.queue : nil,
              job_id: job.respond_to?(:id) ? job.id : nil,
              attempts: job.respond_to?(:attempts) ? job.attempts : nil
            }.compact
          )
          raise
        end

        # `Mailer.delay.welcome(user)` is a PerformableMethod: name it by
        # what it calls rather than by the wrapper.
        def job_name(job)
          payload = job.payload_object
          return payload.display_name.to_s if payload.respond_to?(:display_name)

          payload.class.name.to_s
        rescue StandardError
          "Delayed::Job"
        end
      end
    end
  end
end
