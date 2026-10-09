# frozen_string_literal: true

module ActiveSupport
  # Carries per-thread state from the code that hands work off to the code that
  # runs it elsewhere: a job enqueued now and performed later, or a render made
  # through ActionController::Renderer on an execution state of its own.
  #
  # A library registers what it carries once, under a name, as two callables:
  # +capture+ returns a value in the caller's context, and +restore+ receives
  # that value and a block, and runs the block with the value in place.
  #
  #   ActiveSupport::CarriedState.register :tenant,
  #     capture: -> { Tenant.current },
  #     restore: ->(tenant, &block) { Tenant.with(tenant, &block) }
  #
  # A value of +nil+ is not carried, and its restorer is not called.
  #
  # Values carried into a job cross its queue, so Active Job serializes them as
  # it serializes job arguments: a value must be a type an argument may be, such
  # as a string, a symbol, a hash or a record, which travels as its GlobalID.
  # Values carried into a render are passed as they are.
  module CarriedState
    Hook = Struct.new(:name, :capture, :restore) # :nodoc:

    @hooks = {}.freeze

    class << self
      # Registers how +name+ is captured and restored. Registering a name again
      # replaces its hook.
      def register(name, capture:, restore:)
        name = name.to_sym
        @hooks = @hooks.merge(name => Hook.new(name, capture, restore).freeze).freeze
      end

      # Removes the hook registered under +name+.
      def unregister(name)
        @hooks = @hooks.except(name.to_sym).freeze
      end

      # The names of the registered hooks.
      def names
        @hooks.keys
      end

      # Returns the value of each registered hook in the current context, by
      # name, without the ones that are +nil+.
      def capture
        captured = {}

        @hooks.each_value do |hook|
          value = hook.capture.call
          captured[hook.name] = value unless value.nil?
        end

        captured
      end

      # Runs the block with each value of +captured+, as returned by #capture,
      # restored by the hook registered under its name. Values of names without
      # a hook are ignored.
      def restore(captured, &block)
        return yield if captured.empty?

        @hooks.values.reverse_each.reduce(block) do |inner, hook|
          if captured.key?(hook.name)
            value = captured[hook.name]
            proc { hook.restore.call(value, &inner) }
          else
            inner
          end
        end.call
      end
    end
  end
end
