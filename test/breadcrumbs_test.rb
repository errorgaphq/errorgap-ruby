# frozen_string_literal: true

require "test_helper"

class BreadcrumbsTest < Minitest::Test
  def test_records_message_category_and_metadata
    buffer = Errorgap::Breadcrumbs.new(10)
    buffer.add("ran query", category: "db", metadata: { rows: 3 })

    crumb = buffer.to_a.first
    assert_equal "ran query", crumb[:message]
    assert_equal "db", crumb[:category]
    assert_equal({ rows: 3 }, crumb[:metadata])
    assert crumb[:timestamp], "breadcrumb should carry a timestamp"
  end

  def test_keeps_only_the_most_recent_capacity_entries
    buffer = Errorgap::Breadcrumbs.new(2)
    buffer.add("one")
    buffer.add("two")
    buffer.add("three")

    assert_equal %w[two three], buffer.to_a.map { |c| c[:message] }
  end

  def test_zero_capacity_records_nothing
    buffer = Errorgap::Breadcrumbs.new(0)
    buffer.add("dropped")
    assert_empty buffer.to_a
  end

  def test_clear_empties_the_buffer
    buffer = Errorgap::Breadcrumbs.new(5)
    buffer.add("one")
    buffer.clear
    assert_empty buffer.to_a
  end
end
