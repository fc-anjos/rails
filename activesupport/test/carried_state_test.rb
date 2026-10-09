# frozen_string_literal: true

require_relative "abstract_unit"

class CarriedStateTest < ActiveSupport::TestCase
  CarriedState = ActiveSupport::CarriedState

  setup do
    @hooks = CarriedState.instance_variable_get(:@hooks)
    CarriedState.instance_variable_set(:@hooks, {}.freeze)
    @log = []
  end

  teardown do
    CarriedState.instance_variable_set(:@hooks, @hooks)
    ActiveSupport::IsolatedExecutionState.delete(:carried_state_test_tenant)
  end

  def register_tenant
    CarriedState.register :tenant,
      capture: -> { ActiveSupport::IsolatedExecutionState[:carried_state_test_tenant] },
      restore: ->(tenant, &block) do
        @log << [:tenant, tenant]
        previous = ActiveSupport::IsolatedExecutionState[:carried_state_test_tenant]
        ActiveSupport::IsolatedExecutionState[:carried_state_test_tenant] = tenant
        block.call
      ensure
        ActiveSupport::IsolatedExecutionState[:carried_state_test_tenant] = previous
      end
  end

  test "captures in the caller and restores around a block elsewhere" do
    register_tenant
    ActiveSupport::IsolatedExecutionState[:carried_state_test_tenant] = "acme"
    captured = CarriedState.capture

    tenant = ActiveSupport::IsolatedExecutionState.isolated do
      assert_nil ActiveSupport::IsolatedExecutionState[:carried_state_test_tenant]
      CarriedState.restore(captured) { ActiveSupport::IsolatedExecutionState[:carried_state_test_tenant] }
    end

    assert_equal({ tenant: "acme" }, captured)
    assert_equal "acme", tenant
  end

  test "nil values are not captured, and their restorers are not called" do
    register_tenant

    assert_equal({}, CarriedState.capture)
    assert_equal :done, CarriedState.restore(CarriedState.capture) { :done }
    assert_empty @log
  end

  test "restorers nest in registration order, the first outermost" do
    CarriedState.register :a, capture: -> { 1 }, restore: ->(v, &block) { @log << [:a, v]; block.call.tap { @log << :a_end } }
    CarriedState.register :b, capture: -> { 2 }, restore: ->(v, &block) { @log << [:b, v]; block.call.tap { @log << :b_end } }

    assert_equal :done, CarriedState.restore(CarriedState.capture) { @log << :block; :done }
    assert_equal [[:a, 1], [:b, 2], :block, :b_end, :a_end], @log
  end

  test "values without a registered hook are ignored" do
    register_tenant

    assert_equal :done, CarriedState.restore(other: 1) { :done }
    assert_empty @log
  end

  test "registering a name again replaces its hook, and unregister removes it" do
    CarriedState.register :a, capture: -> { 1 }, restore: ->(v, &block) { block.call }
    CarriedState.register "a", capture: -> { 2 }, restore: ->(v, &block) { block.call }
    assert_equal({ a: 2 }, CarriedState.capture)

    CarriedState.unregister(:a)
    assert_equal [], CarriedState.names
  end
end
