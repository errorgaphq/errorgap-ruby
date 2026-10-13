# frozen_string_literal: true

module Errorgap
  class Configuration
    attr_accessor :endpoint,
                  :project_id,
                  :project_slug,
                  :api_key,
                  :environment,
                  :root_directory,
                  :async,
                  :logger,
                  :filter_keys,
                  :ignore_environments,
                  :apm_enabled,
                  :apm_sample_rate,
                  :logs_enabled,
                  :minimum_log_level,
                  :max_breadcrumbs,
                  :timeout,
                  :queue_size,
                  :capture_user,
                  :track_release,
                  :release_sha,
                  :release_branch,
                  :auth_events,
                  :auth_user,
                  :app_name
    attr_writer :release
    attr_reader :before_notify_hooks

    def initialize
      @endpoint = ENV.fetch("ERRORGAP_ENDPOINT", "http://127.0.0.1:3030")
      @project_id = ENV["ERRORGAP_PROJECT_ID"]
      @project_slug = ENV["ERRORGAP_PROJECT_SLUG"]
      @api_key = ENV["ERRORGAP_API_KEY"]
      @environment = ENV.fetch("RAILS_ENV", ENV.fetch("RACK_ENV", "development"))
      @root_directory = Dir.pwd
      @async = true
      @filter_keys = %w[password password_confirmation token secret api_key authorization cookie]
      @ignore_environments = ENV.fetch("ERRORGAP_IGNORE_ENVIRONMENTS", "").split(",").map(&:strip).reject(&:empty?)
      @apm_enabled = false
      @apm_sample_rate = 1.0
      @logs_enabled = true
      @minimum_log_level = "info"
      @max_breadcrumbs = 25
      # Seconds allowed for each request to errorgap.
      @timeout = 5
      # Payloads held for the background sender; the oldest is dropped when
      # the queue is full.
      @queue_size = 100
      # The deployed version or commit: errors are attributed to the deploy
      # that shipped them. Unset, it is read from the platform's commit
      # variable, a REVISION file or the git checkout.
      @release = ENV["ERRORGAP_RELEASE"].to_s.strip.empty? ? nil : ENV["ERRORGAP_RELEASE"].strip
      @release_sha = nil
      @release_branch = nil
      # Record the release with errorgap (Deploys) when the first error of a
      # process is reported.
      @track_release = false
      # Attach the signed-in user's id and email to errors raised in a
      # request (Warden / Devise).
      @capture_user = true
      @before_notify_hooks = []
      # Sign-ins to this app (Security › Logins). Off until you opt in: they
      # carry user names and IPs.
      @auth_events = false
      # How a signed-in user is named: a method (:email) or a proc. Default:
      # email, username, login, then id.
      @auth_user = nil
      # The app's name in Security › Logins; defaults to the project slug.
      @app_name = nil
    end

    def release
      return @release if @release

      unless defined?(@detected_release) && @detected_root == root_directory
        @detected_root = root_directory
        @detected_release = ReleaseDetector.detect(root_directory)
      end
      @detected_release
    end

    # Runs before a notice is sent, with the notice as a Hash that can be
    # changed in place. Return `false` to drop it.
    #
    #   config.before_notify { |notice| false if notice[:errors][0][:type] == "Timeout::Error" }
    def before_notify(callable = nil, &block)
      hook = callable || block
      @before_notify_hooks << hook if hook.respond_to?(:call)
      hook
    end

    def validate!
      raise ArgumentError, "Errorgap project_slug is required" if blank?(project_slug)

      true
    end

    def ignored_environment?
      Array(ignore_environments).map(&:to_s).include?(environment.to_s)
    end

    private

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
