# :markup: markdown
# frozen_string_literal: true

module ActiveSupport
  module IsolatedExecutionState # :nodoc:
    @isolation_level = nil
    @carried_keys = [].freeze

    Thread.attr_accessor :active_support_execution_state
    Fiber.attr_accessor :active_support_execution_state

    class << self
      attr_reader :isolation_level, :scope

      # Keys that #isolated copies into the store it runs its block on.
      attr_reader :carried_keys

      def isolation_level=(level)
        return if level == @isolation_level

        unless %i(thread fiber).include?(level)
          raise ArgumentError, "isolation_level must be `:thread` or `:fiber`, got: `#{level.inspect}`"
        end

        clear if @isolation_level

        @scope =
          case level
          when :thread; Thread
          when :fiber; Fiber
          end

        @isolation_level = level
      end

      def [](key)
        if state = @scope.current.active_support_execution_state
          state[key]
        end
      end

      def []=(key, value)
        state = (@scope.current.active_support_execution_state ||= {})
        state[key] = value
      end

      def key?(key)
        @scope.current.active_support_execution_state&.key?(key)
      end

      def delete(key)
        @scope.current.active_support_execution_state&.delete(key)
      end

      def clear
        @scope.current.active_support_execution_state&.clear
      end

      def context
        scope.current
      end

      # Declares keys whose values #isolated copies from the caller's store.
      # They are framework plumbing that isolated code cannot run correctly
      # without, such as the executor run it is part of, never values that
      # describe who the code runs for: those reach isolated code only as a job
      # receives them, or as arguments.
      def carry(*keys)
        @carried_keys = (@carried_keys | keys).freeze
      end

      # Runs the block on a store of its own that holds nothing but the carried
      # keys of the caller's, and puts the caller's store back as it ends. What
      # the block writes stays in its store. Values are shared, not copied, so a
      # carried stack that the block pushes to must be popped by the block.
      def isolated
        state = context.active_support_execution_state
        isolated_state = {}

        if state
          @carried_keys.each do |key|
            isolated_state[key] = state[key] if state.key?(key)
          end
        end

        context.active_support_execution_state = isolated_state

        begin
          yield
        ensure
          context.active_support_execution_state = state
        end
      end

      def share_with(other, except: [], &block)
        # Action Controller streaming spawns a new thread and copy thread locals.
        # We do the same here for backward compatibility, but this is very much a hack
        # and streaming should be rethought.
        if state = other.active_support_execution_state
          copied_state = state.dup
          Array(except).each { |key| copied_state.delete(key) }
        end

        old_state, context.active_support_execution_state = context.active_support_execution_state, copied_state
        block.call
      ensure
        context.active_support_execution_state = old_state
      end
    end

    self.isolation_level = :thread
  end
end
