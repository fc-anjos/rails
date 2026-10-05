# frozen_string_literal: true

module ActiveSupport
  class CurrentAttributes
    # Runs a block with CurrentAttributes instances of its own, in an execution
    # context of its own, as a job performed by a queue runs, and puts the
    # caller's instances back as it ends, through
    # CurrentAttributes.restoring_writes, so that nothing the block writes
    # survives it.
    #
    # An instance the block creates receives from the caller's instance of its
    # class nothing but the attributes declared with Isolation.carry. Those are
    # copied as the block first uses the class, so a block that does not use it
    # pays nothing for them.
    class Isolation # :nodoc:
      STATE_KEY = :active_support_current_attributes_isolation

      @carried = {}.freeze

      class << self
        # Attribute names carried into isolated blocks, by instances key.
        attr_reader :carried

        # Declares attributes of +current+ that a block run with <tt>carry:
        # true</tt> receives from its caller. They are for state a framework
        # or library owns that is the same for every user, as it describes
        # where the application runs rather than who it runs for, such as the
        # URL options Active Storage builds URLs from.
        def carry(current, *names)
          key = current.name.to_sym
          @carried = @carried.merge(key => (Array(@carried[key]) | names.map(&:to_sym)).freeze).freeze
        end

        # Runs the block isolated. With +carry+, instances it creates receive
        # the carried attributes. With +on_dropped_read+, it is called with the
        # instance and the attribute name whenever the block reads an attribute
        # that the caller had set to a value other than its default and the
        # block did not receive, while the attribute still holds the value the
        # instance was created with.
        def run(carry: false, on_dropped_read: nil)
          caller_instances = ExecutionContext.current_attributes_instances

          if !caller_instances.empty? && (on_dropped_read || (carry && !@carried.empty?))
            isolation = new(caller_instances, carry ? @carried : {}, on_dropped_read)
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

      def initialize(caller_instances, carried, on_dropped_read)
        @caller_instances = caller_instances
        @carried = carried
        @on_dropped_read = on_dropped_read
      end

      # Gives +instance+, created in the block, what it receives from the
      # caller's instance of its class, and watches its reads of what it did not
      # receive.
      def created(key, instance)
        caller_instance = @caller_instances[key] or return
        carried = @carried[key]

        instance.__send__(:receive_attribute_values, caller_instance, carried) if carried

        if @on_dropped_read
          names = caller_instance.__send__(:attribute_names_changed_from_defaults)
          names -= carried if carried
          instance.__send__(:watch_dropped_reads, names, @on_dropped_read) unless names.empty?
        end
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
