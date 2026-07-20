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
    MAX_CAUSE_DEPTH = 10

    def self.from_exception(error, configuration:, context: {}, environment: {}, session: {}, params: {}, breadcrumbs: [])
      new(
        error: error,
        configuration: configuration,
        context: context,
        environment: environment,
        session: session,
        params: params,
        breadcrumbs: breadcrumbs
      )
    end

    def initialize(error:, configuration:, context:, environment:, session:, params:, breadcrumbs: [])
      @error = error
      @configuration = configuration
      @context = context || {}
      @environment = environment || {}
      @session = session || {}
      @params = params || {}
      @breadcrumbs = Array(breadcrumbs)
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
      context = {
        notifier: "errorgap-ruby",
        notifier_version: Errorgap::VERSION,
        environment: @configuration.environment,
        root_directory: @configuration.root_directory
      }
      causes = collect_causes
      context[:causes] = causes unless causes.empty?
      context[:breadcrumbs] = @breadcrumbs unless @breadcrumbs.empty?
      context
    end

    # Walks the exception's `cause` chain (Ruby's nested exceptions) and merges
    # every link's frames into one backtrace, re-indexed, so the dashboard
    # renders the full chain in a single view.
    def backtrace_frames
      source_frames = 0
      index = 0
      frames = []
      error_chain.each do |link|
        Array(link.backtrace).each do |line|
          file, line_number, function = parse_backtrace_line(line)
          absolute = absolute_frame_path(file)
          frame = {
            file: display_path(absolute),
            line: line_number,
            function: function,
            in_app: within_root?(absolute),
            index: index
          }
          if source_frames < MAX_SOURCE_FRAMES && (source = source_excerpt(absolute, line_number))
            frame[:source] = source
            source_frames += 1
          end
          frames << frame.compact
          index += 1
        end
      end
      frames
    end

    # The causes beyond the root error, as {type, message} pairs.
    def collect_causes
      error_chain.drop(1).map do |link|
        { type: link.class.name, message: link.message.to_s }
      end
    end

    def error_chain
      chain = []
      seen = {}
      current = @error
      while current.is_a?(Exception) && !seen[current.object_id] && chain.length < MAX_CAUSE_DEPTH
        seen[current.object_id] = true
        chain << current
        current = current.cause
      end
      chain
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

    # Ruby <= 3.3 formats frames as `file.rb:42:in `method'` (backtick),
    # Ruby >= 3.4 as `file.rb:42:in 'Class#method'` (straight quote).
    def parse_backtrace_line(line)
      match = line.match(/\A(.+?):(\d+)(?::in [`'](.*)')?\z/)
      return [line, nil, nil] unless match

      [match[1], match[2].to_i, match[3]]
    end

    # Ruby reports the entry script by the (possibly relative) path it was
    # invoked with, while `require`d files use absolute paths. Resolve relative
    # frames against the configured root so the entry point — and framework
    # frames reported relative to the app root — classify as in-app too.
    def absolute_frame_path(file)
      path = file.to_s
      return path if path.start_with?("/") || path.match?(%r{\A[A-Za-z]:[\\/]})

      root = @configuration.root_directory.to_s
      root.empty? ? path : File.expand_path(path, root)
    end

    def within_root?(absolute_path)
      root = @configuration.root_directory.to_s
      return false if root.empty?

      absolute_path == root || absolute_path.start_with?("#{root}/")
    end

    def display_path(absolute_path)
      root = @configuration.root_directory.to_s
      return absolute_path if root.empty?

      absolute_path.sub(%r{\A#{Regexp.escape(root)}/?}, "")
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
