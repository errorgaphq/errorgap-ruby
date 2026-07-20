# frozen_string_literal: true

require "test_helper"

class LogDeliveryTest < Minitest::Test
  def build_configuration
    config = Errorgap::Configuration.new
    config.project_slug = "demo"
    config.environment = "production"
    config.async = false
    config
  end

  def test_normalizes_levels_and_aliases
    assert_equal "warn", Errorgap::LogDelivery.normalize_level("WARNING")
    assert_equal "error", Errorgap::LogDelivery.normalize_level(:err)
    assert_equal "fatal", Errorgap::LogDelivery.normalize_level("critical")
    assert_equal "info", Errorgap::LogDelivery.normalize_level("nonsense")
  end

  def test_delivers_payload_with_normalized_level_and_source
    config = build_configuration
    delivery = Errorgap::LogDelivery.new(config)
    delivered = []
    delivery.define_singleton_method(:deliver) { |payload| delivered << payload }

    delivery.log("payment captured", level: "WARNING", source: "payments")

    payload = delivered.first
    assert_equal "payment captured", payload[:message]
    assert_equal "warn", payload[:level]
    assert_equal "payments", payload[:source]
    assert_equal "production", payload[:environment]
    assert payload[:occurred_at]
  end

  def test_drops_logs_below_minimum_level
    config = build_configuration
    config.minimum_log_level = "warn"
    delivery = Errorgap::LogDelivery.new(config)
    delivery.define_singleton_method(:deliver) { |_payload| flunk "should not deliver below threshold" }

    assert_nil delivery.log("chatty", level: "info")
  end

  def test_skips_when_logs_disabled
    config = build_configuration
    config.logs_enabled = false
    delivery = Errorgap::LogDelivery.new(config)
    delivery.define_singleton_method(:deliver) { |_payload| flunk "should not deliver when disabled" }

    assert_nil delivery.log("anything", level: "error")
  end
end
