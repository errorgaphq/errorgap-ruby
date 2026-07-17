# frozen_string_literal: true

require "test_helper"
require "fileutils"

class NoticeTest < Minitest::Test
  def test_notice_normalizes_exception_payload
    config = Errorgap::Configuration.new
    config.project_id = "prj_123"
    config.project_slug = "demo"
    config.root_directory = "/app"

    error = RuntimeError.new("boom")
    error.set_backtrace(["/app/models/user.rb:12:in `save!'"])

    notice = Errorgap::Notice.from_exception(
      error,
      configuration: config,
      context: { component: "users" },
      environment: {},
      session: {},
      params: { password: "secret", id: "42" }
    ).to_h

    assert_equal "prj_123", notice[:project_id]
    assert_equal "RuntimeError", notice[:errors].first[:type]
    assert_equal "models/user.rb", notice[:errors].first[:backtrace].first[:file]
    assert_equal true, notice[:errors].first[:backtrace].first[:in_app]
    assert_equal "[FILTERED]", notice[:params]["password"]
    assert_equal "42", notice[:params]["id"]
  end

  def test_in_app_frames_include_source_excerpt
    require "tmpdir"
    Dir.mktmpdir do |root|
      file = File.join(root, "app", "models", "user.rb")
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, (1..20).map { |n| "line #{n}" }.join("\n") + "\n")

      config = Errorgap::Configuration.new
      config.root_directory = root

      error = RuntimeError.new("boom")
      error.set_backtrace([
        "#{file}:10:in `save!'",
        "/usr/local/bundle/gems/actionpack-7.1.3/lib/action.rb:2:in `dispatch'"
      ])

      notice = Errorgap::Notice.from_exception(
        error, configuration: config, context: {}, environment: {}, session: {}, params: {}
      ).to_h

      frames = notice[:errors].first[:backtrace]
      source = frames.first[:source]
      refute_nil source, "in-app frame should carry a source excerpt"
      assert_equal 4, source[:start_line]
      assert_equal (4..16).map { |n| "line #{n}" }, source[:lines]

      assert_nil frames.last[:source], "vendor frames should not carry source"
    end
  end

  def test_source_excerpt_clamps_to_file_start
    require "tmpdir"
    Dir.mktmpdir do |root|
      file = File.join(root, "boot.rb")
      File.write(file, "a\nb\nc\n")

      config = Errorgap::Configuration.new
      config.root_directory = root

      error = RuntimeError.new("boom")
      error.set_backtrace(["#{file}:2:in `boot'"])

      notice = Errorgap::Notice.from_exception(
        error, configuration: config, context: {}, environment: {}, session: {}, params: {}
      ).to_h

      source = notice[:errors].first[:backtrace].first[:source]
      assert_equal 1, source[:start_line]
      assert_equal %w[a b c], source[:lines]
    end
  end

  # Ruby 3.4 changed backtrace frames from `file.rb:12:in `save!'` to
  # `file.rb:12:in 'User#save!'` (straight quote, qualified method name).
  def test_parses_ruby_3_4_backtrace_format
    config = Errorgap::Configuration.new
    config.root_directory = "/app"

    error = RuntimeError.new("boom")
    error.set_backtrace(["/app/models/user.rb:12:in 'User#save!'"])

    notice = Errorgap::Notice.from_exception(
      error, configuration: config, context: {}, environment: {}, session: {}, params: {}
    ).to_h

    frame = notice[:errors].first[:backtrace].first
    assert_equal "models/user.rb", frame[:file]
    assert_equal 12, frame[:line]
    assert_equal "User#save!", frame[:function]
  end

  def test_ruby_3_4_in_app_frames_include_source_excerpt
    require "tmpdir"
    Dir.mktmpdir do |root|
      file = File.join(root, "app", "models", "user.rb")
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, (1..20).map { |n| "line #{n}" }.join("\n") + "\n")

      config = Errorgap::Configuration.new
      config.root_directory = root

      error = RuntimeError.new("boom")
      error.set_backtrace(["#{file}:10:in 'block (2 levels) in User#save!'"])

      notice = Errorgap::Notice.from_exception(
        error, configuration: config, context: {}, environment: {}, session: {}, params: {}
      ).to_h

      source = notice[:errors].first[:backtrace].first[:source]
      refute_nil source, "Ruby 3.4-format in-app frame should carry a source excerpt"
      assert_equal 4, source[:start_line]
    end
  end

  def test_source_excerpt_missing_file_is_omitted
    config = Errorgap::Configuration.new
    config.root_directory = "/app"

    error = RuntimeError.new("boom")
    error.set_backtrace(["/app/models/ghost.rb:5:in `haunt'"])

    notice = Errorgap::Notice.from_exception(
      error, configuration: config, context: {}, environment: {}, session: {}, params: {}
    ).to_h

    assert_nil notice[:errors].first[:backtrace].first[:source]
  end
end
