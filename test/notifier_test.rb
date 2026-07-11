# frozen_string_literal: true

require "test_helper"

class NotifierTest < Minitest::Test
  def build_configuration
    config = Errorgap::Configuration.new
    config.project_slug = "demo"
    config.async = false
    config
  end

  def test_notify_skips_delivery_in_ignored_environment
    config = build_configuration
    config.environment = "test"
    config.ignore_environments = %w[test development]

    notifier = Errorgap::Notifier.new(config)
    notifier.define_singleton_method(:deliver) { |_notice| flunk "deliver should not be called" }

    response = notifier.notify(StandardError.new("boom"))

    assert_equal "ignored environment", response.body
    assert response.success?
  end

  def test_notify_delivers_in_other_environments
    config = build_configuration
    config.environment = "production"
    config.ignore_environments = %w[test development]

    notifier = Errorgap::Notifier.new(config)
    delivered = []
    notifier.define_singleton_method(:deliver) do |notice|
      delivered << notice
      Errorgap::Notifier::Response.new(status: 201, body: "created")
    end

    response = notifier.notify(StandardError.new("boom"))

    assert_equal 1, delivered.size
    assert_equal 201, response.status
  end
end
