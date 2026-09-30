# :markup: markdown
# frozen_string_literal: true

require "active_support/core_ext/hash/keys"

module ActiveSupport
  module ExecutionContext # :nodoc:
    class Record # :nodoc:
      attr_reader :store
      attr_accessor :current_attributes_instances

      def initialize
        @store = {}
        @current_attributes_instances = {}
        @stack = []
      end

      def push
        @stack << @store << @current_attributes_instances
        @store = {}
        @current_attributes_instances = {}
        self
      end

      def pop
        @current_attributes_instances = @stack.pop
        @store = @stack.pop
        self
      end

      def flush
        @stack = Array.new(@stack.size) { {} }
        @store = {}
        @current_attributes_instances = {}
        self
      end
    end

    @after_change_callbacks = [].freeze

    # Execution context nesting should only legitimately happen during test
    # because the test case itself is wrapped in an executor, and it might call
    # into a controller or job which should be executed with their own fresh context.
    # However in production this should never happen, and for extra safety we make sure to
    # fully clear the state at the end of the request or job cycle.
    @nestable = false

    class << self
      attr_accessor :nestable, :after_change_callbacks

      def after_change(&block)
        @after_change_callbacks = [*@after_change_callbacks, block].freeze
      end

      # Updates the execution context. If a block is given, it resets the provided keys to their
      # previous value once the block exits.
      def set(**options)
        options.symbolize_keys!
        keys = options.keys

        store = record.store

        previous_context = if block_given?
          keys.zip(store.values_at(*keys)).to_h
        end

        store.merge!(options)
        @after_change_callbacks.each(&:call)

        if block_given?
          begin
            yield
          ensure
            store.merge!(previous_context)
            @after_change_callbacks.each(&:call)
          end
        end
      end

      def []=(key, value)
        record.store[key.to_sym] = value
        @after_change_callbacks.each(&:call)
      end

      def to_h
        record.store.dup
      end

      def push
        if @nestable
          record.push
        else
          clear
        end
        self
      end

      def pop
        if @nestable
          record.pop
        else
          clear
        end
        self
      end

      # Runs the block with a fresh execution context: an empty store and no
      # CurrentAttributes instances. The caller's context is put back when the
      # block exits, without running any reset callbacks. Wrap it in
      # CurrentAttributes.restoring_writes to also undo the side effects of the
      # attribute writers the block called.
      def isolated
        saved_record = IsolatedExecutionState[:active_support_execution_context]
        IsolatedExecutionState[:active_support_execution_context] = nil
        @after_change_callbacks.each(&:call)

        begin
          yield
        ensure
          IsolatedExecutionState[:active_support_execution_context] = saved_record
          @after_change_callbacks.each(&:call)
        end
      end

      def clear
        IsolatedExecutionState[:active_support_execution_context] = nil
      end

      def flush
        record.flush
      end

      def current_attributes_instances
        record.current_attributes_instances
      end

      def current_attributes_instances=(instances)
        record.current_attributes_instances = instances
      end

      private
        def record
          IsolatedExecutionState[:active_support_execution_context] ||= Record.new
        end
    end
  end
end
