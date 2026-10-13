# frozen_string_literal: true

module Errorgap
  # Works out which commit is running when `config.release` is not set, so
  # errors are attributed to a deploy without any setup: the commit variables
  # hosting platforms export, Capistrano's REVISION file, then the checkout's
  # `.git/HEAD`.
  module ReleaseDetector
    ENV_KEYS = %w[
      SOURCE_VERSION HEROKU_SLUG_COMMIT HEROKU_BUILD_COMMIT RENDER_GIT_COMMIT
      RAILWAY_GIT_COMMIT_SHA VERCEL_GIT_COMMIT_SHA KAMAL_VERSION GIT_COMMIT GIT_SHA
    ].freeze

    class << self
      def detect(root_directory, env = ENV)
        ENV_KEYS.each do |key|
          value = env[key].to_s.strip
          return value unless value.empty?
        end
        root = root_directory.to_s
        return nil if root.empty?

        revision_file(root) || git_head(root)
      rescue StandardError
        nil
      end

      private

      def revision_file(root)
        path = File.join(root, "REVISION")
        return nil unless File.file?(path)

        value = File.read(path, 200).to_s.strip
        value.empty? ? nil : value
      end

      def git_head(root)
        git = File.join(root, ".git")
        # A worktree or submodule has a `.git` file pointing at the real dir.
        if File.file?(git)
          pointer = File.read(git, 1024).to_s[/\Agitdir:\s*(.+)$/, 1]
          return nil unless pointer

          git = File.expand_path(pointer.strip, root)
        end
        head_path = File.join(git, "HEAD")
        return nil unless File.file?(head_path)

        head = File.read(head_path, 1024).to_s.strip
        ref = head[/\Aref:\s*(.+)\z/, 1]
        return sha(head) unless ref

        ref_path = File.join(git, ref)
        return sha(File.read(ref_path, 200).to_s.strip) if File.file?(ref_path)

        packed = File.join(git, "packed-refs")
        return nil unless File.file?(packed)

        line = File.foreach(packed).find { |entry| entry.strip.end_with?(" #{ref}") }
        line ? sha(line.split(" ").first) : nil
      end

      def sha(value)
        value.to_s.match?(/\A\h{7,64}\z/) ? value : nil
      end
    end
  end
end
