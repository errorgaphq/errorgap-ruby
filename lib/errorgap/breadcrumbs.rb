# frozen_string_literal: true

require "time"

module Errorgap
  # Fixed-size ring of recent application events (requests, queries, jobs)
  # attached to every notice as context.breadcrumbs. Thread-safe so it can be
  # written from request threads and read at notify time.
  class Breadcrumbs
    def initialize(capacity)
      @capacity = capacity.to_i
      @crumbs = []
      @mutex = Mutex.new
    end

    def add(message, category: nil, metadata: nil)
      return if @capacity <= 0

      crumb = { message: message.to_s, timestamp: Time.now.utc.iso8601(3) }
      crumb[:category] = category.to_s if category
      crumb[:metadata] = metadata if metadata

      @mutex.synchronize do
        @crumbs << crumb
        @crumbs.shift(@crumbs.length - @capacity) if @crumbs.length > @capacity
      end
    end

    def clear
      @mutex.synchronize { @crumbs = [] }
    end

    def to_a
      @mutex.synchronize { @crumbs.dup }
    end
  end
end
