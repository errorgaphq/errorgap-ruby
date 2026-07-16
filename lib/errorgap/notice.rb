# frozen_string_literal: true

require "time"

module Errorgap
  class Notice
    # Lines of context shipped either side of the failing line for in-app
    # frames, and a cap on how many frames include an excerpt so deep
    # backtraces don't inflate the payload.
    SOURCE_RADIUS = 6
    MAX_SOURCE_FRAMES = 25
    MAX_SOURCE_LINE_LENGTH = 400

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
      source_frames = 0
      Array(@error.backtrace).map.with_index do |line, index|
        file, line_number, function = parse_backtrace_line(line)
        frame = {
          file: relative_file(file),
          line: line_number,
          function: function,
          in_app: in_app?(file),
          index: index
        }
        if in_app?(file) && source_frames < MAX_SOURCE_FRAMES &&
           (source = source_excerpt(file, line_number))
          frame[:source] = source
          source_frames += 1
        end
        frame.compact
      end
    end

    # Reads the lines around the failing line so the server can show source
    # without needing repository access. Returns nil when the file cannot be
    # read (precompiled deploys, eval'd code, template paths).
    def source_excerpt(file, line_number)
      return nil unless line_number && line_number >= 1
      return nil unless file && File.file?(file) && File.readable?(file)

      lines = File.readlines(file)
      return nil if lines.empty? || line_number > lines.length

      start_line = [line_number - SOURCE_RADIUS, 1].max
      end_line = [line_number + SOURCE_RADIUS, lines.length].min
      {
        start_line: start_line,
        lines: lines[(start_line - 1)..(end_line - 1)].map do |text|
          text.chomp[0, MAX_SOURCE_LINE_LENGTH]
        end
      }
    rescue StandardError
      nil
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
