# frozen_string_literal: true

require "time"

module Errorgap
  class Notice
    def self.from_exception(error, configuration:, context: {}, environment: {}, session: {}, params: {})
      new(
        error: error,
        configuration: configuration,
        context: context,
        environment: environment,
        session: session,
        params: params
      )
    end

    def initialize(error:, configuration:, context:, environment:, session:, params:)
      @error = error
      @configuration = configuration
      @context = context || {}
      @environment = environment || {}
      @session = session || {}
      @params = params || {}
    end

    def to_h
      {
        project_id: @configuration.project_id,
        received_at: Time.now.utc.iso8601,
        errors: [
          {
            type: @error.class.name,
            message: @error.message.to_s,
            backtrace: backtrace_frames
          }
        ],
        context: default_context.merge(stringify_hash(@context)),
        environment: stringify_hash(@environment),
        session: stringify_hash(@session),
        params: filter_hash(@params)
      }
    end

    private

    def default_context
      {
        notifier: "errorgap-ruby",
        notifier_version: Errorgap::VERSION,
        environment: @configuration.environment,
        root_directory: @configuration.root_directory
      }
    end

    def backtrace_frames
      Array(@error.backtrace).map.with_index do |line, index|
        file, line_number, function = parse_backtrace_line(line)
        {
          file: relative_file(file),
          line: line_number,
          function: function,
          in_app: in_app?(file),
          index: index
        }.compact
      end
    end

    def parse_backtrace_line(line)
      match = line.match(/\A(.+?):(\d+)(?::in `(.*)')?\z/)
      return [line, nil, nil] unless match

      [match[1], match[2].to_i, match[3]]
    end

    def relative_file(file)
      root = @configuration.root_directory.to_s
      return file if root.empty?

      file.to_s.sub(%r{\A#{Regexp.escape(root)}/?}, "")
    end

    def in_app?(file)
      root = @configuration.root_directory.to_s
      !root.empty? && file.to_s.start_with?(root)
    end

    def filter_hash(hash)
      stringify_hash(hash).each_with_object({}) do |(key, value), filtered|
        filtered[key] = sensitive?(key) ? "[FILTERED]" : value
      end
    end

    def sensitive?(key)
      @configuration.filter_keys.any? { |filter| key.to_s.downcase.include?(filter.downcase) }
    end

    def stringify_hash(hash)
      hash.each_with_object({}) do |(key, value), result|
        result[key.to_s] = value.is_a?(Hash) ? stringify_hash(value) : value
      end
    end
  end
end
