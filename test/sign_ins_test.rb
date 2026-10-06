# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class SignInsTest < Minitest::Test
  FakeRequest = Struct.new(:remote_ip, :user_agent, :request_method, :path, :params, :post) do
    def post?
      post
    end
  end

  def setup
    @config = Errorgap.configuration
    @saved = { auth_events: @config.auth_events, async: @config.async, project_slug: @config.project_slug,
               app_name: @config.app_name, auth_user: @config.auth_user, environment: @config.environment }
    @config.project_slug = "demo"
    @config.environment = "production"
    @config.async = false
    @config.auth_events = true
    @delivered = []
    delivered = @delivered
    Errorgap.sign_ins.define_singleton_method(:deliver) { |payload| delivered << payload }
  end

  def teardown
    @saved.each { |k, v| @config.public_send("#{k}=", v) }
    Errorgap.sign_ins.singleton_class.send(:remove_method, :deliver)
  end

  def request(post: true, params: {})
    FakeRequest.new("198.51.100.71", "Safari", post ? "POST" : "GET", "/users/sign_in", params, post)
  end

  def test_reports_a_sign_in_with_request_details
    Errorgap.sign_in("success", user: "mara@oxcoffee.com", request: request)
    payload = @delivered.first
    assert_equal "demo", payload[:app]
    assert_equal "production", payload[:environment]
    assert_match(/\Aerrorgap-ruby /, payload[:sdk])
    event = payload[:events].first
    assert_equal "success", event[:outcome]
    assert_equal "mara@oxcoffee.com", event[:user]
    assert_equal "198.51.100.71", event[:ip]
    assert_equal "POST /users/sign_in", event[:path]
    assert event[:occurred_at]
  end

  def test_off_by_default_and_unknown_outcomes_dropped
    @config.auth_events = false
    Errorgap.sign_in("success", user: "x")
    @config.auth_events = true
    Errorgap.sign_in("teleported", user: "x")
    assert_empty @delivered
  end

  def test_app_name_overrides_the_slug
    @config.app_name = "oxcoffee-web"
    Errorgap.sign_in("password_reset", user: "x")
    assert_equal "oxcoffee-web", @delivered.first[:app]
  end

  User = Struct.new(:id, :email)

  def test_warden_success_names_the_user_and_skips_remember_me
    hooks = Errorgap::WardenHooks
    hooks.stub(:request_for, request) do
      auth = Struct.new(:env, :winning_strategy).new({}, Struct.new(:key).new(:database_authenticatable))
      hooks.on_success(User.new(7, "mara@oxcoffee.com"), auth)
      assert_equal "mara@oxcoffee.com", @delivered.last[:events].first[:user]

      @config.auth_user = :id
      hooks.on_success(User.new(7, "mara@oxcoffee.com"), auth)
      assert_equal "7", @delivered.last[:events].first[:user]

      remembered = Struct.new(:env, :winning_strategy).new({}, Struct.new(:key).new(:rememberable))
      hooks.on_success(User.new(7, "mara@oxcoffee.com"), remembered)
      assert_equal 2, @delivered.size
    end
  end

  def test_warden_failure_only_for_sign_in_attempts
    hooks = Errorgap::WardenHooks
    attempt = request(params: { "user" => { "email" => "admin@oxcoffee.com", "password" => "hunter2" } })
    hooks.stub(:request_for, attempt) do
      hooks.on_failure({}, { scope: :user, message: :invalid, attempted_path: "/users/sign_in?token=abc" })
      event = @delivered.last[:events].first
      assert_equal "POST /users/sign_in", event[:path], "the form's path, not the failure app's"
      assert_equal ["failure", "admin@oxcoffee.com"], [event[:outcome], event[:user]]
      refute_includes JSON.generate(@delivered.last), "hunter2"

      hooks.on_failure({}, { scope: :user, message: :locked })
      assert_equal "locked", @delivered.last[:events].first[:outcome]

      # Visiting a protected page signed out is not an attempt.
      hooks.on_failure({}, { scope: :user, message: :unauthenticated })
    end
    hooks.stub(:request_for, request(post: false)) do
      hooks.on_failure({}, { scope: :user, message: :invalid })
    end
    assert_equal 2, @delivered.size
  end
end
