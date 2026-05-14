# frozen_string_literal: true

require "rails/generators"

module Errorgap
  class InstallGenerator < ::Rails::Generators::Base
    def create_initializer
      create_file "config/initializers/errorgap.rb", <<~RUBY
        # frozen_string_literal: true

        Errorgap.configure do |config|
          config.endpoint = ENV.fetch("ERRORGAP_ENDPOINT", "http://127.0.0.1:3030")
          config.project_slug = ENV["ERRORGAP_PROJECT_SLUG"]
          config.project_id = ENV["ERRORGAP_PROJECT_ID"]
          config.api_key = ENV["ERRORGAP_API_KEY"]
          config.environment = Rails.env
          config.root_directory = Rails.root.to_s
          config.logger = Rails.logger
        end
      RUBY
    end
  end
end
