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
end
