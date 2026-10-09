# frozen_string_literal: true

module ActiveSupport
  class CurrentAttributes
    # Runs a block with CurrentAttributes instances of its own, in an execution
    # context of its own, as a job performed by a queue runs, and puts the
    # caller's instances back as it ends, through
    # CurrentAttributes.restoring_writes, so that nothing the block writes
    # survives it. An instance the block creates receives nothing from the
    # caller's instance of its class.
    class Isolation # :nodoc:
      STATE_KEY = :active_support_current_attributes_isolation

      # The isolation and the restoration of the block it runs stay reachable
      # when the block also runs on a store of its own.
      IsolatedExecutionState.carry(STATE_KEY, :active_support_current_attributes_restoration)

      class << self
        # Runs the block isolated. With +on_dropped_read+, it is called with the
        # instance and the attribute name whenever the block reads an attribute
        # that the caller had set to a value other than its default, while the
        # attribute still holds the value the instance was created with.
        def run(on_dropped_read: nil)
          caller_instances = ExecutionContext.current_attributes_instances

          if on_dropped_read && !caller_instances.empty?
            isolation = new(caller_instances, on_dropped_read)
          end

          CurrentAttributes.restoring_writes(isolated: true) do
            ExecutionContext.isolated do
              outer = IsolatedExecutionState[STATE_KEY]
              IsolatedExecutionState[STATE_KEY] = isolation

              begin
                yield
              ensure
                IsolatedExecutionState[STATE_KEY] = outer
              end
            end
          end
        end

        def created(key, instance)
          IsolatedExecutionState[STATE_KEY]&.created(key, instance)
        end
      end

      def initialize(caller_instances, on_dropped_read)
        @caller_instances = caller_instances
        @on_dropped_read = on_dropped_read
      end

      # Watches the reads of +instance+, created in the block, of what the
      # caller's instance of its class had set.
      def created(key, instance)
        caller_instance = @caller_instances[key] or return
        names = caller_instance.__send__(:attribute_names_changed_from_defaults)
        instance.__send__(:watch_dropped_reads, names, @on_dropped_read) unless names.empty?
      end

      # The attributes of an instance created in an isolated block with
      # +on_dropped_read+. Calls it for each read of an attribute the caller had
      # set and the instance did not receive, until the block writes it.
      class DroppedAttributes < Hash # :nodoc:
        def initialize(current, attributes, names, on_dropped_read)
          super()
          replace(attributes)
          @current = current
          @names = names
          @on_dropped_read = on_dropped_read
        end

        def [](name)
          @on_dropped_read.call(@current, name) if @names.include?(name)
          super
        end

        def []=(name, value)
          @names -= [name] if @names.include?(name)
          super
        end

        # Called by CurrentAttributes#attributes, which reads every attribute.
        def dup
          @names.each { |name| @on_dropped_read.call(@current, name) }
          to_h
        end
      end
    end
  end
end
