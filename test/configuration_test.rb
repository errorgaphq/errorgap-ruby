# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def test_project_slug_is_required
    config = Errorgap::Configuration.new
    config.project_slug = nil

    assert_raises(ArgumentError) { config.validate! }
  end

  def test_project_slug_passes_validation
    config = Errorgap::Configuration.new
    config.project_slug = "demo"

    assert_equal true, config.validate!
  end

  def test_ignore_environments_defaults_to_empty
    config = Errorgap::Configuration.new

    assert_equal [], config.ignore_environments
    refute config.ignored_environment?
  end

  def test_ignored_environment_matches_configured_environment
    config = Errorgap::Configuration.new
    config.environment = "test"
    config.ignore_environments = %w[test development]

    assert config.ignored_environment?
  end

  def test_ignored_environment_handles_symbols
    config = Errorgap::Configuration.new
    config.environment = :development
    config.ignore_environments = %w[development]

    assert config.ignored_environment?
  end

  def test_ignored_environment_is_false_for_other_environments
    config = Errorgap::Configuration.new
    config.environment = "production"
    config.ignore_environments = %w[test development]

    refute config.ignored_environment?
  end
end
