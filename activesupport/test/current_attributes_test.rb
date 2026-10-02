# frozen_string_literal: true

require_relative "abstract_unit"
require "active_support/current_attributes/test_helper"

class CurrentAttributesTest < ActiveSupport::TestCase
  # CurrentAttributes is automatically reset in Rails app via executor hooks set in railtie
  # But not in Active Support's own test suite.
  include ActiveSupport::CurrentAttributes::TestHelper

  Person = Struct.new(:id, :name, :time_zone)

  class Current < ActiveSupport::CurrentAttributes
    attribute :counter_integer, default: 0
    attribute :counter_callable, default: -> { 0 }
    attribute :world, :account, :person, :request
    delegate :time_zone, to: :person

    before_reset { Session.previous = person&.id }

    resets do
      Session.current = nil
    end

    resets :clear_time_zone

    def account=(account)
      super
      self.person = Person.new(1, "#{account}'s person")
    end

    def person=(person)
      super
      Time.zone = person&.time_zone
      Session.current = person&.id
    end

    def set_world_and_account(world:, account:)
      self.world = world
      self.account = account
    end

    def get_world_and_account(hash)
      hash[:world] = world
      hash[:account] = account
      hash
    end

    def respond_to_test; end

    def request
      "#{super} something"
    end

    def intro
      "#{person.name}, in #{time_zone}"
    end

    private
      def clear_time_zone
        Time.zone = "UTC"
      end
  end

  class Session < ActiveSupport::CurrentAttributes
    attribute :current, :previous
  end

  class Zone < ActiveSupport::CurrentAttributes
    attribute :time_zone

    def time_zone=(time_zone)
      super
      Time.zone = time_zone
    end
  end

  # Use library specific minitest hook to catch Time.zone before reset is called via TestHelper
  def before_setup
    @original_time_zone = Time.zone
    super
  end

  # Use library specific minitest hook to set Time.zone after reset is called via TestHelper
  def after_teardown
    super
    Time.zone = @original_time_zone
  end

  setup { assert_nil Session.previous, "Expected Session to not have leaked state" }

  test "read and write attribute" do
    Current.world = "world/1"
    assert_equal "world/1", Current.world
  end

  test "read and write attribute with default value" do
    assert_equal 0, Current.counter_integer

    Current.counter_integer += 1

    assert_equal 1, Current.counter_integer

    Current.reset

    assert_equal 0, Current.counter_integer
  end

  test "read attribute with default callable" do
    assert_equal 0, Current.counter_callable

    Current.counter_callable += 1

    assert_equal 1, Current.counter_callable

    Current.reset

    assert_equal 0, Current.counter_callable
  end

  test "read overwritten attribute method" do
    Current.request = "request/1"
    assert_equal "request/1 something", Current.request
  end

  test "set attribute via overwritten method" do
    Current.account = "account/1"
    assert_equal "account/1", Current.account
    assert_equal "account/1's person", Current.person.name
  end

  test "set auxiliary class via overwritten method" do
    Current.person = Person.new(42, "David", "Central Time (US & Canada)")
    assert_equal "Central Time (US & Canada)", Time.zone.name
    assert_equal 42, Session.current
  end

  test "resets auxiliary classes via callback" do
    Current.person = Person.new(42, "David", "Central Time (US & Canada)")
    assert_equal "Central Time (US & Canada)", Time.zone.name

    Current.reset
    assert_equal "UTC", Time.zone.name
    assert_equal 42, Session.previous
    assert_nil Session.current
  end

  test "set auxiliary class based on current attributes via before callback" do
    Current.person = Person.new(42, "David", "Central Time (US & Canada)")
    assert_nil Session.previous
    assert_equal 42, Session.current

    Current.reset
    assert_equal 42, Session.previous
    assert_nil Session.current
  end

  test "set attribute only via scope" do
    Current.world = "world/1"

    Current.set(world: "world/2") do
      assert_equal "world/2", Current.world
    end

    assert_equal "world/1", Current.world
  end

  test "set multiple attributes" do
    Current.world = "world/1"
    Current.account = "account/1"

    Current.set(world: "world/2", account: "account/2") do
      assert_equal "world/2", Current.world
      assert_equal "account/2", Current.account
    end

    assert_equal "world/1", Current.world
    assert_equal "account/1", Current.account

    hash = { world: "world/2", account: "account/2" }
    Current.set(hash) do
      assert_equal "world/2", Current.world
      assert_equal "account/2", Current.account
    end
  end

  test "using keyword arguments" do
    Current.set_world_and_account(world: "world/1", account: "account/1")

    assert_equal "world/1", Current.world
    assert_equal "account/1", Current.account

    hash = {}
    assert_same hash, Current.get_world_and_account(hash)
    assert_equal "world/1", hash[:world]
    assert_equal "account/1", hash[:account]
  end

  setup { @testing_teardown = false }
  teardown { assert_equal 42, Session.current if @testing_teardown }

  test "accessing attributes in teardown" do
    Session.current = 42
    @testing_teardown = true
  end

  test "delegation" do
    Current.person = Person.new(42, "David", "Central Time (US & Canada)")
    assert_equal "Central Time (US & Canada)", Current.time_zone
    assert_equal "Central Time (US & Canada)", Current.instance.time_zone
  end

  test "all methods forward to the instance" do
    Current.person = Person.new(42, "David", "Central Time (US & Canada)")
    assert_equal "David, in Central Time (US & Canada)", Current.intro
    assert_equal "David, in Central Time (US & Canada)", Current.instance.intro
  end

  test "respond_to? for methods that have not been called" do
    assert_equal true, Current.respond_to?("respond_to_test")
  end

  test "CurrentAttributes defaults do not leak between classes" do
    Class.new(ActiveSupport::CurrentAttributes) { attribute :counter_integer, default: 100 }
    Current.reset

    assert_equal 0, Current.counter_integer
  end

  test "CurrentAttributes use fiber-local variables" do
    previous_level = ActiveSupport::IsolatedExecutionState.isolation_level
    ActiveSupport::IsolatedExecutionState.isolation_level = :fiber

    Session.current = 42
    enumerator = Enumerator.new do |yielder|
      yielder.yield Session.current
    end
    assert_nil enumerator.next
  ensure
    ActiveSupport::IsolatedExecutionState.isolation_level = previous_level
  end

  test "CurrentAttributes can use thread-local variables" do
    previous_level = ActiveSupport::IsolatedExecutionState.isolation_level
    ActiveSupport::IsolatedExecutionState.isolation_level = :thread

    Session.current = 42
    enumerator = Enumerator.new do |yielder|
      yielder.yield Session.current
    end
    assert_equal 42, enumerator.next
  ensure
    ActiveSupport::IsolatedExecutionState.isolation_level = previous_level
  end

  test "CurrentAttributes doesn't populate #attributes when not using defaults" do
    assert_equal({ counter_integer: 0, counter_callable: 0 }, Current.attributes)
  end

  test "#attributes returns different objects each time" do
    assert_not_same Current.attributes, Current.attributes
  end

  test "CurrentAttributes restricted attribute names" do
    assert_raises ArgumentError, match: /Restricted attribute names: reset, set/ do
      class InvalidAttributeNames < ActiveSupport::CurrentAttributes
        attribute :reset, :foo, :set
      end
    end
  end

  test "CurrentAttributes restricted attribute name :attributes" do
    assert_raises ArgumentError, match: /Restricted attribute names: attributes/ do
      class InvalidAttributesAttributeName < ActiveSupport::CurrentAttributes
        attribute :attributes, :foo
      end
    end
  end

  test "CurrentAttributes restricts attribute names shadowing internal methods" do
    assert_raises ArgumentError, match: /Restricted attribute names: attribute, defaults/ do
      class InvalidInternalAttributeNames < ActiveSupport::CurrentAttributes
        attribute :attribute, :foo, :defaults
      end
    end
  end

  test "method_added hook doesn't reach the instance. Fix for #54646" do
    current = Class.new(ActiveSupport::CurrentAttributes) do
      def self.name
        "MyCurrent"
      end

      def foo; end # Sets the cache because of a `method_added` hook

      attribute :bar, default: {}
    end

    assert_instance_of(Hash, current.bar)
  end

  test "instance delegators are eagerly defined" do
    current = Class.new(ActiveSupport::CurrentAttributes) do
      def self.name
        "MyCurrent"
      end

      def regular
        :regular
      end

      attribute :attr, default: :att
    end

    assert current.singleton_class.method_defined?(:attr)
    assert current.singleton_class.method_defined?(:attr=)
    assert current.singleton_class.method_defined?(:regular)
  end

  test "attribute delegators have precise signature" do
    current = Class.new(ActiveSupport::CurrentAttributes) do
      def self.name
        "MyCurrent"
      end

      attribute :attr, default: :att
    end

    assert_equal [], current.method(:attr).parameters
    assert_equal [[:req, :value]], current.method(:attr=).parameters
  end


  test "provided_attribute? is true while a set block names the attribute" do
    assert_not Current.provided_attribute?(:world)

    Current.set(world: "world/1") do
      assert Current.provided_attribute?(:world)
      assert_not Current.provided_attribute?(:account)

      Current.set(account: "account/1") do
        assert Current.provided_attribute?(:world)
        assert Current.provided_attribute?(:account)
      end

      assert_not Current.provided_attribute?(:account)
    end

    Current.set("world" => "world/2") { assert Current.provided_attribute?(:world) }
    assert_not Current.provided_attribute?(:world)
  end

  test "provided_attribute? is false after a set block raises" do
    assert_raises(RuntimeError) do
      Current.set(world: "world/1") { raise "boom" }
    end

    assert_not Current.provided_attribute?(:world)
  end

  test "provided_attribute? leaves out the set blocks opened before opened_set_blocks was called" do
    Current.set(world: "world/1") do
      opened = ActiveSupport::CurrentAttributes.opened_set_blocks

      assert Current.provided_attribute?(:world)
      assert_not Current.provided_attribute?(:world, opened_after: opened)

      Current.set(account: "account/1") do
        assert Current.provided_attribute?(:account, opened_after: opened)
        assert_not Current.provided_attribute?(:world, opened_after: opened)
      end

      Current.set(world: "world/2") { assert Current.provided_attribute?(:world, opened_after: opened) }
      Session.set(current: 42) { assert Session.provided_attribute?(:current, opened_after: opened) }
    end
  end

  test "opened_set_blocks counts the set blocks opened on the thread" do
    opened = ActiveSupport::CurrentAttributes.opened_set_blocks

    Current.set(world: "world/1") { Session.set(current: 42) { } }
    assert_equal opened + 2, ActiveSupport::CurrentAttributes.opened_set_blocks

    assert_equal 0, Thread.new { ActiveSupport::CurrentAttributes.opened_set_blocks }.value
  end

  test "observing_reads reports reads of attributes that differ from their defaults" do
    Current.world = "world/1"
    Current.counter_integer = 0
    Current.counter_callable = 1
    Session.current = 42

    reads = observe_reads do
      assert_equal "world/1", Current.world
      assert_equal 0, Current.counter_integer
      assert_equal 1, Current.counter_callable
      assert_nil Current.account
      assert_equal 42, Session.current
      assert_nil Session.previous
    end

    assert_equal [[Current, :world, "world/1"], [Current, :counter_callable, 1], [Session, :current, 42]], reads
  end

  test "observing_reads reports reads of every attribute unless only_set is true" do
    Current.world = "world/1"

    reads = observe_reads(only_set: false) do
      assert_equal "world/1", Current.world
      assert_equal 0, Current.counter_integer
      assert_nil Current.account
    end

    assert_equal [[Current, :world, "world/1"], [Current, :counter_integer, 0], [Current, :account, nil]], reads
  end

  test "observing_reads reports every observed attribute when reading all attributes" do
    Current.world = "world/1"

    reads = observe_reads { Current.attributes }

    assert_equal [[Current, :world, "world/1"]], reads
  end

  test "observing_reads does not report an attribute after the block writes it, nor reads after the block" do
    world = Current.world = +"world/1"

    reads = observe_reads do
      Current.world = "world/2"
      assert_equal "world/2", Current.world
    end
    assert_equal "world/2", Current.world

    Current.world = world
    Current.world
    assert_empty reads
  end

  test "observing_reads does not report what a set block in the block provides, and reports the original once it closes" do
    Current.world = "world/1"

    reads = observe_reads do
      Current.set(world: "world/2") { assert_equal "world/2", Current.world }
      assert_equal "world/1", Current.world
    end

    assert_equal [[Current, :world, "world/1"]], reads
  end

  test "observing_reads reports an attribute again once the block writes its original value back" do
    world = Current.world = +"world/1"

    reads = observe_reads do
      Current.world = "world/2"
      Current.world
      Current.world = world
      Current.world
    end

    assert_equal [[Current, :world, "world/1"]], reads
  end

  test "observing_reads reports an attribute provided by a set block opened before the block" do
    Current.world = "world/1"

    reads = Current.set(world: "world/2") do
      observe_reads { Current.world }
    end

    assert_equal [[Current, :world, "world/2"]], reads
  end

  test "observing_reads does not observe instances created in the block" do
    reads = observe_reads do
      Session.current = 42
      Session.current
    end

    assert_empty reads
  end

  test "observing_reads observes instances created in the block unless only_set is true" do
    reads = observe_reads(only_set: false) do
      assert_nil Session.current
      Session.previous = 42
      Session.previous
    end

    assert_equal 42, Session.previous

    Session.current
    ActiveSupport::ExecutionContext.clear
    Session.current
    assert_equal [[Session, :current, nil]], reads
  end

  test "observing_reads keeps what a reset in the block installs" do
    world = Current.world = +"world/1"

    reads = observe_reads do
      Current.reset
      Current.world
    end
    assert_nil Current.world

    Current.world = world
    Current.world
    assert_empty reads
  end

  test "observing_reads stops observing, keeping the writes, when the block raises" do
    Current.world = "world/1"
    reads = []

    assert_raises(RuntimeError) do
      ActiveSupport::CurrentAttributes.observing_reads(->(current, name) { reads << name }) do
        Current.account = "account/1"
        raise "boom"
      end
    end

    assert_equal "account/1", Current.account
    assert_equal "world/1", Current.world
    assert_empty reads
  end

  test "observing_reads reports the reads of a nested block to both blocks" do
    Current.world = "world/1"
    inner_reads = nil

    outer_reads = observe_reads(only_set: false) do
      Current.account = "account/1"
      inner_reads = observe_reads(only_set: false) { Current.world + Current.account }
    end
    assert_equal "account/1", Current.account
    assert_equal "world/1", Current.world

    assert_equal [[Current, :world, "world/1"], [Current, :account, "account/1"]], inner_reads
    assert_equal [[Current, :world, "world/1"]], outer_reads
  end

  test "restoring_writes sets back what the block writes, through the writers" do
    Current.world = "world/1"
    Current.person = Person.new(7, "david", "Europe/Lisbon")

    ActiveSupport::CurrentAttributes.restoring_writes do
      Current.world = "world/2"
      Current.person = Person.new(42, "jane", "Asia/Tokyo")

      assert_equal "Asia/Tokyo", Time.zone.name
      assert_equal 42, Session.current
    end

    assert_equal "world/1", Current.world
    assert_equal "david", Current.person.name
    assert_equal "Europe/Lisbon", Time.zone.name
    assert_equal 7, Session.current
  end

  test "restoring_writes calls no writer for an attribute the block only reads" do
    Current.person = Person.new(7, "david", "Europe/Lisbon")
    Session.current = 99

    ActiveSupport::CurrentAttributes.restoring_writes do
      assert_equal "david", Current.person.name
    end

    assert_equal 99, Session.current
  end

  test "restoring_writes discards the instances created in the block" do
    instance = ActiveSupport::CurrentAttributes.restoring_writes do
      Current.world = "world/2"
      Current.instance
    end

    assert_not_same instance, Current.instance
    assert_nil Current.world
  end

  test "restoring_writes sets back the writes of an instance created in the block through its writers" do
    Time.zone = "Europe/Lisbon"

    ActiveSupport::CurrentAttributes.restoring_writes do
      Current.person = Person.new(42, "jane", "Asia/Tokyo")
      assert_equal "Asia/Tokyo", Time.zone.name
    end

    assert_nil Time.zone
    assert_nil Current.person
  end

  test "restoring_writes sets back what the block writes when it raises" do
    Current.world = "world/1"

    assert_raises(RuntimeError) do
      ActiveSupport::CurrentAttributes.restoring_writes do
        Current.world = "world/2"
        raise "boom"
      end
    end

    assert_equal "world/1", Current.world
  end

  test "restoring_writes runs no reset callbacks, and sets back what a reset in the block clears" do
    Current.world = "world/1"
    Current.person = Person.new(7, "david", "Europe/Lisbon")

    ActiveSupport::CurrentAttributes.restoring_writes { Current.world = "world/2" }

    assert_nil Session.previous
    assert_equal 7, Session.current

    ActiveSupport::CurrentAttributes.restoring_writes do
      Current.reset
      assert_nil Current.world
      assert_equal 7, Session.previous
    end

    assert_equal "world/1", Current.world
    assert_equal "david", Current.person.name
    assert_equal "Europe/Lisbon", Time.zone.name
    assert_nil Session.previous
    assert_equal 7, Session.current
  end

  test "restoring_writes keeps what set blocks in the block put back, and nests" do
    Current.world = "world/1"

    ActiveSupport::CurrentAttributes.restoring_writes do
      Current.set(world: "world/2") { assert_equal "world/2", Current.world }
      assert_equal "world/1", Current.world

      Current.world = "outer"
      ActiveSupport::CurrentAttributes.restoring_writes do
        Current.world = "inner"
        Session.current = 42
      end

      assert_equal "outer", Current.world
      assert_nil Session.current
    end

    assert_equal "world/1", Current.world
  end

  test "restoring_writes around an isolated block sets back the caller's values through the caller's writers" do
    Current.person = Person.new(7, "david", "Europe/Lisbon")

    restoring_writes_isolated do
      assert_nil Current.person
      Current.person = Person.new(42, "jane", "Asia/Tokyo")

      assert_equal "Asia/Tokyo", Time.zone.name
      assert_equal 42, Session.current
    end

    assert_equal "david", Current.person.name
    assert_equal "Europe/Lisbon", Time.zone.name
    assert_equal 7, Session.current
  end

  test "restoring_writes around nested isolated blocks sets back each caller's values" do
    Current.person = Person.new(7, "david", "Europe/Lisbon")

    restoring_writes_isolated do
      Current.person = Person.new(42, "jane", "Asia/Tokyo")

      restoring_writes_isolated do
        Current.person = Person.new(99, "bob", "America/Chicago")
      end

      assert_equal "jane", Current.person.name
      assert_equal "Asia/Tokyo", Time.zone.name
    end

    assert_equal "david", Current.person.name
    assert_equal "Europe/Lisbon", Time.zone.name
  end

  test "restoring_writes around an isolated block sets back a class the caller has no instance of through the block's writers" do
    instance = restoring_writes_isolated do
      Zone.time_zone = "Asia/Tokyo"
      assert_equal "Asia/Tokyo", Time.zone.name
      Zone.instance
    end

    assert_nil Time.zone
    assert_not_same instance, Zone.instance
  end

  test "restoring_writes around an isolated block compares the block's values with the caller's, not with those it started with" do
    Zone.time_zone = "Europe/Lisbon"

    restoring_writes_isolated do
      Zone.set(time_zone: nil) { Zone.time_zone = "Asia/Tokyo" }
      assert_nil Time.zone
    end

    assert_equal "Europe/Lisbon", Time.zone.name
  end

  test "restoring_writes around an isolated block sets back what an executor's reset of the block's instances undid" do
    ActiveSupport::ExecutionContext.with(nestable: false) do
      # simulate executor hooks from active_support/railtie.rb
      executor = Class.new(ActiveSupport::Executor)
      executor.to_run { ActiveSupport::ExecutionContext.push }
      executor.to_complete do
        ActiveSupport::CurrentAttributes.clear_all
        ActiveSupport::ExecutionContext.pop
      end

      Current.person = Person.new(7, "david", "Europe/Lisbon")

      restoring_writes_isolated do
        executor.wrap { assert_nil Current.person }
        assert_equal "UTC", Time.zone.name
      end

      assert_equal "david", Current.person.name
      assert_equal "Europe/Lisbon", Time.zone.name
      assert_equal 7, Session.current
      assert_nil Session.previous
    end
  end

  test "set and restore attributes when re-entering the executor" do
    ActiveSupport::ExecutionContext.with(nestable: true) do
      # simulate executor hooks from active_support/railtie.rb
      executor = Class.new(ActiveSupport::Executor)
      executor.to_run do
        ActiveSupport::ExecutionContext.push
      end

      executor.to_complete do
        ActiveSupport::CurrentAttributes.clear_all
        ActiveSupport::ExecutionContext.pop
      end

      Current.world = "world/1"
      Current.account = "account/1"

      assert_equal "world/1", Current.world
      assert_equal "account/1", Current.account

      Current.set(world: "world/2", account: "account/2") do
        assert_equal "world/2", Current.world
        assert_equal "account/2", Current.account

        executor.wrap do
          assert_nil Current.world
          assert_nil Current.account

          Current.world = "world/3"
          Current.account = "account/3"

          assert_equal "world/3", Current.world
          assert_equal "account/3", Current.account

          ActiveSupport::CurrentAttributes.clear_all

          assert_nil Current.world
          assert_nil Current.account
        end
      end

      assert_equal "world/1", Current.world
      assert_equal "account/1", Current.account
    end
  end

  private
    def restoring_writes_isolated(&block)
      ActiveSupport::CurrentAttributes.restoring_writes do
        ActiveSupport::ExecutionContext.isolated(&block)
      end
    end

    def observe_reads(only_set: true, &block)
      reads = []
      on_read = ->(current, name, value) { reads << [current.class, name, value] }
      ActiveSupport::CurrentAttributes.observing_reads(on_read, only_set: only_set, &block)
      reads
    end
end
