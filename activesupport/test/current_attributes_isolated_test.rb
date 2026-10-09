# frozen_string_literal: true

require_relative "abstract_unit"
require "active_support/current_attributes/test_helper"

class CurrentAttributesIsolationTest < ActiveSupport::TestCase
  include ActiveSupport::CurrentAttributes::TestHelper

  Isolation = ActiveSupport::CurrentAttributes::Isolation

  class Current < ActiveSupport::CurrentAttributes
    attribute :user, :account
    attribute :count, default: 0

    def account=(account)
      super
      Time.zone = account&.fetch(:time_zone)
    end
  end

  class Location < ActiveSupport::CurrentAttributes
    attribute :host, :path
  end

  teardown do
    Time.zone = nil
  end

  test "runs the block with empty attributes and puts the caller's back" do
    Current.user = "david"

    Isolation.run do
      assert_nil Current.user
      Current.user = "jose"
    end

    assert_equal "david", Current.user
  end

  test "puts the caller's attributes back when the block raises" do
    Current.user = "david"

    assert_raises(RuntimeError) do
      Isolation.run do
        Current.user = "jose"
        raise "boom"
      end
    end

    assert_equal "david", Current.user
  end

  test "undoes the side effects of the block's writers through the caller's writers" do
    Current.account = { time_zone: "Copenhagen" }

    Isolation.run do
      Current.account = { time_zone: "Tokyo" }
      assert_equal "Tokyo", Time.zone.name
    end

    assert_equal "Copenhagen", Time.zone.name
  end

  test "gives the block nothing of the caller's instances" do
    Location.host = "example.com"

    Isolation.run do
      assert_nil Location.host
    end
  end

  test "on_dropped_read is called for reads of attributes the caller had set and the block did not receive" do
    Current.user = "david"
    Current.count = 0
    Location.host = "example.com"
    reads = []

    Isolation.run(on_dropped_read: ->(current, name) { reads << [current.class, name] }) do
      Current.user
      Current.user
      Current.account
      Current.count
      Location.path
    end

    assert_equal [[Current, :user], [Current, :user]], reads
  end

  test "on_dropped_read is called for a read through attributes" do
    Current.user = "david"
    reads = []

    Isolation.run(on_dropped_read: ->(current, name) { reads << name }) do
      Current.instance.attributes
    end

    assert_equal [:user], reads
  end

  test "on_dropped_read is not called once the block writes the attribute" do
    Current.user = "david"
    reads = []

    Isolation.run(on_dropped_read: ->(current, name) { reads << name }) do
      Current.user ||= "jose"
      Current.user
    end

    assert_equal [:user], reads
  end
end
