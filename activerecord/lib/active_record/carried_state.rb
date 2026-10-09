# frozen_string_literal: true

module ActiveRecord
  # Registers the per-thread state Active Record owns with
  # ActiveSupport::CarriedState, so that work run elsewhere for the caller, such
  # as a render isolated from the caller's execution state, connects as the
  # caller does.
  module CarriedState # :nodoc:
    CONNECTED_TO_STACK = :active_record_connected_to_stack
    PROHIBITED_SHARD_SWAPPING = :active_record_prohibit_shard_swapping

    class << self
      # The caller's connected_to stack, with the role, shard and
      # prevent_writes of each entry for the connection classes it names, and
      # the connection classes prohibited from swapping shards.
      def capture_connection
        stack = ActiveSupport::IsolatedExecutionState[CONNECTED_TO_STACK]
        prohibited = ActiveSupport::IsolatedExecutionState[PROHIBITED_SHARD_SWAPPING]

        if (stack && !stack.empty?) || (prohibited && !prohibited.empty?)
          [stack ? stack.dup : [], prohibited]
        end
      end

      def restore_connection((entries, prohibited))
        stack = Base.connected_to_stack
        depth = stack.size
        previously_prohibited = ActiveSupport::IsolatedExecutionState[PROHIBITED_SHARD_SWAPPING]

        stack.concat(entries)
        ActiveSupport::IsolatedExecutionState[PROHIBITED_SHARD_SWAPPING] = prohibited if prohibited

        begin
          yield
        ensure
          stack.pop(stack.size - depth)
          ActiveSupport::IsolatedExecutionState[PROHIBITED_SHARD_SWAPPING] = previously_prohibited
        end
      end

      # The shard of each connection class the caller swapped the shard of, when
      # ActiveRecord.carry_shard_into_jobs is enabled.
      def capture_shards
        return unless ActiveRecord.carry_shard_into_jobs

        stack = ActiveSupport::IsolatedExecutionState[CONNECTED_TO_STACK]
        return if stack.nil? || stack.empty?

        classes = stack.flat_map { |entry| entry[:shard] ? entry[:klasses] : [] }.uniq
        shards = classes.filter_map do |klass|
          shard = klass.current_shard
          [klass, shard] unless shard == klass.default_shard
        end

        shards unless shards.empty?
      end

      # Connects each connection class to its shard, but for those already
      # connected to it, such as in a render that also received the caller's
      # whole connected_to stack.
      def restore_shards(shards)
        stack = Base.connected_to_stack
        depth = stack.size

        shards.each do |klass, shard|
          stack << { role: nil, shard: shard, prevent_writes: nil, klasses: [klass] } unless klass.current_shard == shard
        end

        begin
          yield
        ensure
          stack.pop(stack.size - depth)
        end
      end
    end

    # The role, prevent_writes and shard-swapping prohibition describe how the
    # caller runs, as a request read from a replica, not what a job is for, so
    # they never cross a queue: a job enqueued from a request on the reading
    # role must be able to write.
    ActiveSupport::CarriedState.register :active_record_connected_to,
      capture: -> { CarriedState.capture_connection },
      restore: ->(connection, &block) { CarriedState.restore_connection(connection, &block) },
      local: true

    ActiveSupport::CarriedState.register :active_record_shards,
      capture: -> { CarriedState.capture_shards },
      restore: ->(shards, &block) { CarriedState.restore_shards(shards, &block) }
  end
end
