# frozen_string_literal: true

require_relative "abstract_unit"
require "active_support/execution_context/test_helper"
require "active_support/core_ext/object/with"
require "active_support/testing/ractors_assertions"

class ExecutionContextTest < ActiveSupport::TestCase
  # ExecutionContext is automatically reset in Rails app via executor hooks set in railtie
  # But not in Active Support's own test suite.
  include ActiveSupport::ExecutionContext::TestHelper
  include ActiveSupport::Testing::RactorsAssertions

  test "#set restore the modified keys when the block exits" do
    assert_nil ActiveSupport::ExecutionContext.to_h[:foo]
    ActiveSupport::ExecutionContext.set(foo: "bar") do
      assert_equal "bar", ActiveSupport::ExecutionContext.to_h[:foo]
      ActiveSupport::ExecutionContext.set(foo: "plop") do
        assert_equal "plop", ActiveSupport::ExecutionContext.to_h[:foo]
      end
      assert_equal "bar", ActiveSupport::ExecutionContext.to_h[:foo]

      ActiveSupport::ExecutionContext[:direct_assignment] = "present"
      ActiveSupport::ExecutionContext.set(multi_assignment: "present")
    end

    assert_nil ActiveSupport::ExecutionContext.to_h[:foo]

    assert_equal "present", ActiveSupport::ExecutionContext.to_h[:direct_assignment]
    assert_equal "present", ActiveSupport::ExecutionContext.to_h[:multi_assignment]
  end

  test "#[] reads a key, and nil without an execution context" do
    ActiveSupport::ExecutionContext.clear
    assert_nil ActiveSupport::ExecutionContext[:foo]

    ActiveSupport::ExecutionContext[:foo] = "bar"
    assert_equal "bar", ActiveSupport::ExecutionContext[:foo]
    assert_equal "bar", ActiveSupport::ExecutionContext["foo"]
  end

  test "#pop after #flush does not corrupt execution context" do
    ActiveSupport::ExecutionContext.with(nestable: true) do
      # simulate executor hooks from active_support/railtie.rb
      executor = Class.new(ActiveSupport::Executor)

      executor.to_run do
        ActiveSupport::ExecutionContext.push
      end
      executor.to_complete do
        ActiveSupport::ExecutionContext.pop
      end
      executor.wrap do
        # simulate app.reloader.before_class_unload hooks from active_support/railtie.rb
        ActiveSupport::ExecutionContext.flush
      end

      assert_equal({}, ActiveSupport::ExecutionContext.to_h)
    end
  end

  test "#set coerce keys to symbol" do
    ActiveSupport::ExecutionContext.set("foo" => "bar") do
      assert_equal "bar", ActiveSupport::ExecutionContext.to_h[:foo]
    end
  end

  test "#[]= coerce keys to symbol" do
    ActiveSupport::ExecutionContext["symbol_key"] = "symbolized"
    assert_equal "symbolized", ActiveSupport::ExecutionContext.to_h[:symbol_key]
  end

  test "#to_h returns a copy of the context" do
    ActiveSupport::ExecutionContext[:foo] = 42
    context = ActiveSupport::ExecutionContext.to_h
    context[:foo] = 43
    assert_equal 42, ActiveSupport::ExecutionContext.to_h[:foo]
  end

  class Current < ActiveSupport::CurrentAttributes
    attribute :user

    singleton_class.attr_accessor :resets_count
    self.resets_count = 0
    resets { self.class.resets_count += 1 }
  end

  test "#isolated runs the block with an empty context and restores the caller's afterwards" do
    ActiveSupport::ExecutionContext[:controller] = "caller"
    Current.user = "caller"

    ActiveSupport::ExecutionContext.isolated do
      assert_equal({}, ActiveSupport::ExecutionContext.to_h)
      assert_nil Current.user

      ActiveSupport::ExecutionContext[:job] = "isolated"
      Current.user = "isolated"
    end

    assert_equal({ controller: "caller" }, ActiveSupport::ExecutionContext.to_h)
    assert_equal "caller", Current.user
  ensure
    Current.reset
  end

  test "#isolated restores the caller's context when nestable is false" do
    ActiveSupport::ExecutionContext.with(nestable: false) do
      ActiveSupport::ExecutionContext[:controller] = "caller"

      ActiveSupport::ExecutionContext.isolated do
        ActiveSupport::ExecutionContext.push
        assert_equal({}, ActiveSupport::ExecutionContext.to_h)
        ActiveSupport::ExecutionContext.pop
      end

      assert_equal({ controller: "caller" }, ActiveSupport::ExecutionContext.to_h)
    end
  end

  test "#isolated restores the caller's context when the block raises" do
    ActiveSupport::ExecutionContext[:controller] = "caller"
    Current.user = "caller"

    assert_raises(RuntimeError) do
      ActiveSupport::ExecutionContext.isolated do
        Current.user = "isolated"
        raise "boom"
      end
    end

    assert_equal({ controller: "caller" }, ActiveSupport::ExecutionContext.to_h)
    assert_equal "caller", Current.user
  ensure
    Current.reset
  end

  test "#isolated runs no reset callbacks" do
    Current.user = "caller"

    assert_no_changes -> { Current.resets_count } do
      ActiveSupport::ExecutionContext.isolated { Current.user = "isolated" }
    end
    assert_equal "caller", Current.user
  ensure
    Current.reset
  end

  test "#isolated calls the after_change callbacks when it swaps the context in and out" do
    ActiveSupport::ExecutionContext.with(after_change_callbacks: [].freeze) do
      seen = []
      ActiveSupport::ExecutionContext[:controller] = "caller"
      ActiveSupport::ExecutionContext.after_change { seen << ActiveSupport::ExecutionContext.to_h[:controller] }

      ActiveSupport::ExecutionContext.isolated { }

      assert_equal [nil, "caller"], seen
    end
  end

  test "callbacks are ractor safe" do
    ActiveSupport::ExecutionContext.with(after_change_callbacks: [].freeze) do
      ActiveSupport::ExecutionContext.after_change(&ActiveSupport::Ractors.shareable_proc { })

      assert_ractor_shareable ActiveSupport::ExecutionContext.after_change_callbacks
    end
  end
end
