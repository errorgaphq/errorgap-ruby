# frozen_string_literal: true

module Errorgap
  # Makes caller-supplied data safe to serialize: masks sensitive keys at any
  # depth, cuts long strings and large or deeply nested collections, replaces
  # invalid UTF-8 and breaks reference cycles. Without it one binary param or
  # a self-referencing hash loses the whole notice.
  class Sanitizer
    FILTERED = "[FILTERED]"
    TRUNCATED = "[TRUNCATED]"
    CIRCULAR = "[CIRCULAR]"
    MAX_STRING = 4096
    MAX_ITEMS = 128
    MAX_DEPTH = 8

    # `filter_keys` entries are substrings (case-insensitive) or Regexps.
    def initialize(filter_keys = [])
      @filter_keys = Array(filter_keys).map { |key| key.is_a?(Regexp) ? key : key.to_s.downcase }
    end

    # Truncate only.
    def clean(value)
      walk(value, false, 0, {})
    end

    # Truncate and mask sensitive keys.
    def filter(value)
      walk(value, true, 0, {})
    end

    def self.string(value, limit = MAX_STRING)
      text = value.to_s
      text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
      text = text.scrub("?") unless text.valid_encoding?
      text.length > limit ? "#{text[0, limit]}#{TRUNCATED}" : text
    rescue StandardError
      "[UNPRINTABLE]"
    end

    private

    def walk(value, masking, depth, seen)
      case value
      when Hash
        nested(value, depth, seen) do
          value.first(MAX_ITEMS).each_with_object({}) do |(key, item), result|
            name = self.class.string(key, 256)
            result[name] = masking && sensitive?(name) ? FILTERED : walk(item, masking, depth + 1, seen)
          end
        end
      when Array
        nested(value, depth, seen) do
          value.first(MAX_ITEMS).map { |item| walk(item, masking, depth + 1, seen) }
        end
      when String, Symbol
        self.class.string(value)
      when Integer, NilClass, TrueClass, FalseClass
        value
      when Float
        value.finite? ? value : value.to_s
      else
        if value.respond_to?(:to_hash)
          walk(value.to_hash, masking, depth, seen)
        else
          self.class.string(value)
        end
      end
    rescue StandardError
      "[UNPRINTABLE]"
    end

    def nested(value, depth, seen)
      return TRUNCATED if depth >= MAX_DEPTH
      return CIRCULAR if seen[value.object_id]

      seen[value.object_id] = true
      begin
        yield
      ensure
        seen.delete(value.object_id)
      end
    end

    def sensitive?(key)
      lowered = key.downcase
      @filter_keys.any? do |filter|
        filter.is_a?(Regexp) ? filter.match?(key) : lowered.include?(filter)
      end
    end
  end
end
