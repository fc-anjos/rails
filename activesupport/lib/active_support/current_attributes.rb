# :markup: markdown
# frozen_string_literal: true

require "active_support/callbacks"
require "active_support/execution_context"
require "active_support/core_ext/object/with"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/module/delegation"

module ActiveSupport
  # Current Attributes
  # ==================
  #
  # Abstract super class that provides a thread-isolated attributes singleton, which resets automatically
  # before and after each request. This allows you to keep all the per-request attributes easily
  # available to the whole system.
  #
  # The following full app-like example demonstrates how to use a Current class to
  # facilitate easy access to the global, per-request attributes without passing them deeply
  # around everywhere:
  #
  # ```
  # # app/models/current.rb
  # class Current < ActiveSupport::CurrentAttributes
  #   attribute :account, :user
  #   attribute :request_id, :user_agent, :ip_address
  #
  #   resets { Time.zone = nil }
  #
  #   def user=(user)
  #     super
  #     self.account = user.account
  #     Time.zone    = user.time_zone
  #   end
  # end
  #
  # # app/controllers/concerns/authentication.rb
  # module Authentication
  #   extend ActiveSupport::Concern
  #
  #   included do
  #     before_action :authenticate
  #   end
  #
  #   private
  #     def authenticate
  #       if authenticated_user = User.find_by(id: cookies.encrypted[:user_id])
  #         Current.user = authenticated_user
  #       else
  #         redirect_to new_session_url
  #       end
  #     end
  # end
  #
  # # app/controllers/concerns/set_current_request_details.rb
  # module SetCurrentRequestDetails
  #   extend ActiveSupport::Concern
  #
  #   included do
  #     before_action do
  #       Current.request_id = request.uuid
  #       Current.user_agent = request.user_agent
  #       Current.ip_address = request.ip
  #     end
  #   end
  # end
  #
  # class ApplicationController < ActionController::Base
  #   include Authentication
  #   include SetCurrentRequestDetails
  # end
  #
  # class MessagesController < ApplicationController
  #   def create
  #     Current.account.messages.create(message_params)
  #   end
  # end
  #
  # class Message < ApplicationRecord
  #   belongs_to :creator, default: -> { Current.user }
  #   after_create { |message| Event.create(record: message) }
  # end
  #
  # class Event < ApplicationRecord
  #   before_create do
  #     self.request_id = Current.request_id
  #     self.user_agent = Current.user_agent
  #     self.ip_address = Current.ip_address
  #   end
  # end
  # ```
  #
  # A word of caution: It's easy to overdo a global singleton like Current and tangle your model as a result.
  # Current should only be used for a few, top-level globals, like account, user, and request details.
  # The attributes stuck in Current should be used by more or less all actions on all requests. If you start
  # sticking controller-specific attributes in there, you're going to create a mess.
  class CurrentAttributes
    include ActiveSupport::Callbacks
    define_callbacks :reset

    NOT_SET = Object.new.freeze # :nodoc:

    # Holds the attributes of an instance while CurrentAttributes.observing_reads
    # runs, reporting the reads that return the value an observed attribute held
    # when the block started.
    class ObservedAttributes < Hash # :nodoc:
      def initialize(current, attributes, observed_values, on_read)
        super()
        replace(attributes)
        @current = current
        @observed_values = observed_values
        @on_read = on_read
      end

      def [](name)
        value = super
        observe(name, value)
        value
      end

      # Called by CurrentAttributes#attributes, which reads every attribute.
      def dup
        each { |name, value| observe(name, value) }
        to_h
      end

      private
        # A value the observed code wrote, directly or with a #set block, is its own.
        def observe(name, value)
          if @observed_values.key?(name) && @observed_values[name].equal?(value)
            @on_read.call(@current, name)
          end
        end
    end

    # Holds, while CurrentAttributes.restoring_writes runs, the attribute values
    # the caller's instances had as the block started and those each instance
    # created in the block was created with, and puts the caller's values back
    # once it ends.
    class Restoration # :nodoc:
      def initialize(instances)
        @instances = instances
        @values = instances.transform_values { |instance| instance.__send__(:attribute_values) }
        @created = nil
      end

      def created(key, instance)
        (@created ||= []) << [key, instance, instance.__send__(:attribute_values)]
      end

      def restore
        @created&.reverse_each do |key, instance, values|
          if caller_values = @values[key]
            @instances[key].__send__(:restore_attribute_values, caller_values, instance)
          else
            instance.__send__(:restore_attribute_values, values)
          end
        end

        @values.each do |key, values|
          @instances[key].__send__(:restore_attribute_values, values)
        end
      end
    end

    class << self
      # Returns singleton instance for this class in this thread. If none exists, one is created.
      def instance
        current_instances[current_instances_key] ||= create_instance
      end

      # Declares one or more attributes that will be given both class and instance accessor methods.
      #
      # #### Options
      #
      # * `:default` - The default value for the attributes. If the value
      #   is a proc or lambda, it will be called whenever an instance is
      #   constructed. Otherwise, the value will be duplicated with `#dup`.
      #   Default values are re-assigned when the attributes are reset.
      def attribute(*names, default: NOT_SET)
        invalid_attribute_names = names.map(&:to_sym) & INVALID_ATTRIBUTE_NAMES
        if invalid_attribute_names.any?
          raise ArgumentError, "Restricted attribute names: #{invalid_attribute_names.join(", ")}"
        end

        Delegation.generate(singleton_class, names, to: :instance, nilable: false, signature: "")
        Delegation.generate(singleton_class, names.map { |n| "#{n}=" }, to: :instance, nilable: false, signature: "value")

        ActiveSupport::CodeGenerator.batch(generated_attribute_methods, __FILE__, __LINE__) do |owner|
          names.each do |name|
            owner.define_cached_method(name, namespace: :current_attributes) do |batch|
              batch <<
                "def #{name}" <<
                "@attributes[:#{name}]" <<
                "end"
            end
            owner.define_cached_method("#{name}=", namespace: :current_attributes) do |batch|
              batch <<
                "def #{name}=(value)" <<
                "@attributes[:#{name}] = value" <<
                "end"
            end
          end
        end

        self.defaults = defaults.merge(names.index_with { default })
      end

      # Calls this callback before #reset is called on the instance. Used for resetting external collaborators that depend on current values.
      def before_reset(*methods, &block)
        set_callback :reset, :before, *methods, &block
      end

      # Calls this callback after #reset is called on the instance. Used for resetting external collaborators, like Time.zone.
      def resets(*methods, &block)
        set_callback :reset, :after, *methods, &block
      end
      alias_method :after_reset, :resets

      delegate :set, :reset, to: :instance

      def clear_all # :nodoc:
        if instances = current_instances
          instances.values.each(&:reset)
          instances.clear
        end
      end

      # Runs the block, calling +on_read+ with the instance and the attribute name
      # whenever the block reads an attribute that is set, on an instance that
      # exists when the block starts, and the read returns the value the attribute
      # held then. An attribute is set when its value differs from the attribute's
      # default, which is resolved again to compare. A value the block writes,
      # directly or with a #set block, is not reported, and is kept after the block.
      def observing_reads(on_read) # :nodoc:
        observed = {}.compare_by_identity

        current_instances.values.each do |instance|
          if original_attributes = instance.__send__(:observe_reads, on_read)
            observed[instance] = original_attributes
          end
        end

        yield
      ensure
        observed.each do |instance, original_attributes|
          instance.__send__(:stop_observing_reads, original_attributes)
        end
      end

      # Runs the block, and then puts back the attribute values the caller had
      # as the block started, through the attribute writers, as a #set block
      # does when it ends, so that writers with side effects, such as setting
      # +Time.zone+, undo what the block's writes did. Nothing the block writes
      # survives it, also when it raises.
      #
      # The block can run on the caller's instances, or on instances of its own
      # inside ExecutionContext.isolated. Each instance the block used is compared
      # with the caller's instance of its class, and the caller's writer is called,
      # with the caller's value, for each attribute whose value is not the same
      # object. An attribute the block only read is not written back, unless the
      # block read it on an instance of its own that holds another value. A class
      # the caller has no instance of is set back, through the writers of the
      # block's instance, to the values that instance was created with, and the
      # instance is discarded. No reset callbacks run, and a writer that cannot
      # take the caller's value raises, as at the end of a #set block.
      def restoring_writes # :nodoc:
        instances = current_instances
        restoration = Restoration.new(instances)
        outer_restoration = IsolatedExecutionState[:active_support_current_attributes_restoration]
        IsolatedExecutionState[:active_support_current_attributes_restoration] = restoration
        ExecutionContext.current_attributes_instances = instances.dup

        yield
      ensure
        if restoration
          IsolatedExecutionState[:active_support_current_attributes_restoration] = outer_restoration
          ExecutionContext.current_attributes_instances = instances
          restoration.restore
        end
      end

      # Returns the number of #set blocks opened so far on this thread or fiber.
      # Passed to #provided_attribute? as +opened_after+, it leaves out the blocks
      # opened before this call.
      def opened_set_blocks # :nodoc:
        IsolatedExecutionState[:active_support_current_attributes_opened_set_blocks] || 0
      end

      private
        def generated_attribute_methods
          @generated_attribute_methods ||= Module.new.tap { |mod| include mod }
        end

        def current_instances
          ExecutionContext.current_attributes_instances
        end

        def current_instances_key
          @current_instances_key ||= name.to_sym
        end

        def create_instance
          instance = new
          IsolatedExecutionState[:active_support_current_attributes_restoration]&.created(current_instances_key, instance)
          instance
        end

        def method_missing(name, ...)
          instance.public_send(name, ...)
        end

        def respond_to_missing?(name, _)
          instance.respond_to?(name) || super
        end

        def method_added(name)
          super

          # We try to generate instance delegators early to not rely on method_missing.
          return if name == :initialize

          # If the added method isn't public, we don't delegate it.
          return unless public_method_defined?(name)

          # If we already have a class method by that name, we don't override it.
          return if singleton_class.method_defined?(name) || singleton_class.private_method_defined?(name)

          Delegation.generate(singleton_class, [name], to: :instance, as: self, nilable: false)
        end
    end

    class_attribute :defaults, instance_writer: false, default: {}.freeze

    attr_writer :attributes

    def initialize
      @attributes = resolve_defaults
      @provided_attributes = nil
    end

    def attributes
      @attributes.dup
    end

    # Expose one or more attributes within a block. Old values are returned after the block concludes.
    # Example demonstrating the common use of needing to set Current attributes outside the request-cycle:
    #
    # ```
    # class Chat::PublicationJob < ApplicationJob
    #   def perform(attributes, room_number, creator)
    #     Current.set(person: creator) do
    #       Chat::Publisher.publish(attributes: attributes, room_number: room_number)
    #     end
    #   end
    # end
    # ```
    #
    # The attributes named in a `set` block are provided to the code that runs in
    # it. A render through ActionController::Renderer made while a controller is
    # processing an action, or an Action Cable channel a command, can read the
    # attributes set for the request only when a `set` block opened during the
    # action provides them, or it logs or raises, depending on
    # `config.action_controller.action_on_unprovided_renderer_input`. A block
    # still open when the action method is called, such as one that a middleware,
    # an `around_action` or an `around_command` opens around the action, holds
    # the request's state, and provides nothing to such a render:
    #
    # ```
    # Current.set(user: nil) do
    #   message.broadcast_append_to message.room
    # end
    # ```
    def set(attributes, &block)
      (@provided_attributes ||= []) << [open_set_block, attributes]

      begin
        with(**attributes, &block)
      ensure
        @provided_attributes.pop
      end
    end

    # Returns whether an open #set block names the attribute. With +opened_after+,
    # a number returned by CurrentAttributes.opened_set_blocks, only the blocks
    # opened since that call count.
    def provided_attribute?(name, opened_after: 0) # :nodoc:
      @provided_attributes&.reverse_each do |opened, attributes|
        return false if opened <= opened_after
        return true if attributes.key?(name) || attributes.key?(name.name)
      end
      false
    end

    # Reset all attributes. Should be called before and after actions, when used as a per-request singleton.
    def reset
      run_callbacks :reset do
        self.attributes = resolve_defaults
      end
    end

    private
      def observe_reads(on_read)
        return if ObservedAttributes === @attributes

        observed_values = attribute_values_changed_from_defaults
        return if observed_values.empty?

        original_attributes = @attributes
        @attributes = ObservedAttributes.new(self, original_attributes, observed_values, on_read)
        original_attributes
      end

      def stop_observing_reads(original_attributes)
        @attributes = original_attributes.replace(@attributes)
      end

      def attribute_values
        {}.update(@attributes)
      end

      # Calls the writer of each attribute whose value in +source+, this instance
      # or one a block used in its place, is not the same object as in +values+,
      # with the value in +values+.
      def restore_attribute_values(values, source = self)
        source.__send__(:attribute_names_changed_from, values)&.each do |name|
          public_send("#{name}=", values[name])
        end
      end

      def attribute_names_changed_from(values)
        names = nil

        @attributes.each do |name, value|
          (names ||= []) << name unless values.key?(name) && values[name].equal?(value)
        end
        values.each_key do |name|
          (names ||= []) << name unless @attributes.key?(name)
        end

        names
      end

      def attribute_values_changed_from_defaults
        @attributes.select do |name, value|
          default = defaults.fetch(name, NOT_SET)

          default_value =
            if Proc === default
              default.call
            elsif default != NOT_SET
              default
            end

          value != default_value
        end
      end

      def resolve_defaults
        defaults.each_with_object({}) do |(key, value), result|
          if value != NOT_SET
            result[key] = Proc === value ? value.call : value.dup
          end
        end
      end

      # Numbers the #set blocks of the thread or fiber in the order they open.
      def open_set_block
        IsolatedExecutionState[:active_support_current_attributes_opened_set_blocks] =
          (IsolatedExecutionState[:active_support_current_attributes_opened_set_blocks] || 0) + 1
      end

      # Declaring an attribute by one of these names would shadow the methods
      # CurrentAttributes itself relies on. Computed at the very end of the
      # class body so that all the methods defined above are captured.
      INVALID_ATTRIBUTE_NAMES = (methods(false) + private_methods(false) + instance_methods(false) + private_instance_methods(false)).uniq.sort.freeze # :nodoc:
  end
end
