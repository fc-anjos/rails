# frozen_string_literal: true

require "cases/helper"

class CarriedStateTest < ActiveRecord::TestCase
  self.use_transactional_tests = false

  class AnimalsRecord < ActiveRecord::Base
    self.abstract_class = true
    self.connection_class = true
  end

  teardown do
    ActiveRecord.carry_shard_into_jobs = false
  end

  def elsewhere(captured, &block)
    ActiveSupport::IsolatedExecutionState.isolated do
      ActiveSupport::CarriedState.restore(captured, &block)
    end
  end

  def connection_state
    [ActiveRecord::Base.current_role, ActiveRecord::Base.current_shard, ActiveRecord::Base.current_preventing_writes,
     AnimalsRecord.current_role, AnimalsRecord.current_shard, AnimalsRecord.current_preventing_writes]
  end

  test "nested connected_to blocks across connection classes round-trip into isolated state" do
    expected, captured = ActiveRecord::Base.connected_to(role: :reading, shard: :one) do
      AnimalsRecord.connected_to(role: :writing, shard: :two) do
        [connection_state, ActiveSupport::CarriedState.capture]
      end
    end

    assert_equal [:reading, :one, true, :writing, :two, false], expected
    assert_equal expected, elsewhere(captured) { connection_state }
    assert_empty ActiveRecord::Base.connected_to_stack
  end

  test "connected_to_many round-trips into isolated state" do
    expected, captured = ActiveRecord::Base.connected_to_many(AnimalsRecord, role: :reading) do
      [connection_state, ActiveSupport::CarriedState.capture]
    end

    assert_equal [:writing, :default, false, :reading, :default, true], expected
    assert_equal expected, elsewhere(captured) { connection_state }
  end

  test "a prohibition to swap shards is carried" do
    captured = AnimalsRecord.connected_to(shard: :one) do
      AnimalsRecord.prohibit_shard_swapping { ActiveSupport::CarriedState.capture }
    end

    elsewhere(captured) do
      assert_predicate AnimalsRecord, :shard_swapping_prohibited?
      assert_raises(ActiveRecord::ShardSwapProhibitedError) { AnimalsRecord.connected_to(shard: :two) { } }
    end
  end

  test "nothing is captured outside connected_to" do
    captured = ActiveSupport::CarriedState.capture

    assert_not captured.key?(:active_record_connected_to)
    assert_not captured.key?(:active_record_shards)
  end

  test "work that crosses a queue receives neither the role nor the stack" do
    captured = ActiveRecord::Base.connected_to(role: :reading, shard: :one) do
      ActiveSupport::CarriedState.capture(local: false)
    end

    assert_equal({}, captured.slice(:active_record_connected_to, :active_record_shards))
  end

  test "with carry_shard_into_jobs, work that crosses a queue receives the shard of each connection class, and not the role" do
    ActiveRecord.carry_shard_into_jobs = true

    captured = ActiveRecord::Base.connected_to(role: :reading, shard: :one) do
      AnimalsRecord.connected_to(shard: :two) do
        ActiveSupport::CarriedState.capture(local: false)
      end
    end

    assert_equal [:writing, :one, false, :writing, :two, false], elsewhere(captured) { connection_state }
  end

  test "encryption contexts are carried into isolated state, and not across a queue" do
    captured, queued = ActiveRecord::Encryption.protecting_encrypted_data do
      [ActiveSupport::CarriedState.capture, ActiveSupport::CarriedState.capture(local: false)]
    end

    assert_not queued.key?(:active_record_encryption_contexts)
    elsewhere(captured) do
      assert_predicate ActiveRecord::Encryption.context, :frozen_encryption?
    end
    assert_not_predicate ActiveRecord::Encryption.context, :frozen_encryption?
  end
end
