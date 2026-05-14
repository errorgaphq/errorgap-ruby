# frozen_string_literal: true

require "test_helper"

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
end
