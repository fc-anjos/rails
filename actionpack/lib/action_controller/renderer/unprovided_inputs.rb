# frozen_string_literal: true

# :markup: markdown

module ActionController
  class Renderer
    # Reports the reads a render makes of inputs it was not given, as
    # `config.action_controller.action_on_unprovided_renderer_input` says. One is
    # created for each render the setting applies to.
    class UnprovidedInputs # :nodoc:
      EVENT = "unprovided_renderer_input.action_controller"

      # What a render lacks when it was not given each request input.
      REQUEST_INPUTS = { session: "a session", cookies: "cookies", flash: "a flash" }.freeze

      # What the thread that renders is processing for a user, if anything: the
      # controller processing an action, or the ActionCable::Connection::ChannelCommand
      # being processed. Each keeps, in `set_blocks_opened_before_action`, the number
      # of `Current.set` blocks opened before its action method is called, or, until
      # it is, before processing started; the controller keeps it private.
      attr_reader :processing

      def initialize(action, controller, render_args)
        @action = action
        @controller = controller
        @rendered = rendered_in(render_args)
        @processing = ActiveSupport::ExecutionContext[:controller] || ActiveSupport::ExecutionContext[:channel_command]
        @reported = nil
      end

      # Called by the withheld session, cookie jar and flash. +key+ is `nil` for a
      # read of the whole input, and +read+ names a read its key does not name.
      def read(input, key = nil, read = nil)
        key = key&.to_s

        report(input, key, read) do
          read ||= key ? "#{input}[#{key.to_sym.inspect}]" : input.to_s
          message(read, " that was not given #{REQUEST_INPUTS.fetch(input)}", "a request",
            "read them from `Current` attributes set with a `Current.set` block around the render")
        end
      end

      # Called by CurrentAttributes.observing_reads for a read of an attribute
      # that was set when the render started.
      def read_current_attribute(current, name)
        return if current.provided_attribute?(name, opened_after: processing.send(:set_blocks_opened_before_action))

        read = "#{current.class.name}.#{name}"

        report(:current_attributes, read) do
          provide = "provide it with `#{current.class.name}.set(#{name}: ...) { ... }`"
          provide += ". For the response to the current request, use `render_to_string`" if processing_controller

          message(read, ", and no `#{current.class.name}.set` block opened during the action provides it",
            "#{processed_action}, during which the attribute was set", provide)
        end
      end

      private
        def report(input, key, read = nil)
          # Raise on every read, so that rescuing one does not let the next one through.
          raise UnprovidedInputError, yield if @action == :raise
          return unless (@reported ||= Set.new).add?([input, key, read])

          case @action
          when :log
            @controller.logger&.warn yield
          when :notify
            ActiveSupport::Notifications.instrument(EVENT,
              controller: processing_controller,
              input: input,
              key: key,
              message: yield,
              stack_trace: caller
            )
          end
        end

        def processing_controller
          processing if ActionController::Metal === processing
        end

        def processed_action
          if processing_controller
            "the action `#{processing.class.name}##{processing.action_name}`"
          else
            processing.processed_action_description
          end
        end

        def message(read, unprovided, request, provide)
          "`#{read}` was read by a render#{render_name} through ActionController::Renderer#{unprovided}. " \
            "The render is not part of #{request}, and its output may be sent to other users, " \
            "for example in a Turbo Stream broadcast. Pass the values it needs as locals, or #{provide}."
        end

        def render_name
          " of `#{@rendered}`" if @rendered
        end

        # The partial, template or action the render's arguments name, read before
        # rendering normalizes them.
        def rendered_in(render_args)
          options = Hash === render_args.last ? render_args.last : {}
          rendered = options[:partial] || options[:template] || options[:action] || render_args.first
          rendered = rendered.to_partial_path if rendered.respond_to?(:to_partial_path)
          rendered if String === rendered || Symbol === rendered
        end
    end
  end
end
