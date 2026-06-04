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
                  :apm_enabled,
                  :apm_sample_rate

    def initialize
      @endpoint = ENV.fetch("ERRORGAP_ENDPOINT", "http://127.0.0.1:3030")
      @project_id = ENV["ERRORGAP_PROJECT_ID"]
      @project_slug = ENV["ERRORGAP_PROJECT_SLUG"]
      @api_key = ENV["ERRORGAP_API_KEY"]
      @environment = ENV.fetch("RAILS_ENV", ENV.fetch("RACK_ENV", "development"))
      @root_directory = Dir.pwd
      @async = true
      @filter_keys = %w[password password_confirmation token secret api_key authorization cookie]
      @apm_enabled = false
      @apm_sample_rate = 1.0
    end

    def validate!
      raise ArgumentError, "Errorgap project_slug is required" if blank?(project_slug)

      true
    end

    private

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
