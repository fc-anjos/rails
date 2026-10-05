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

      def initialize(action, controller, render_args)
        @action = action
        @controller = controller
        @rendered = rendered_in(render_args)
        @reported = nil
      end

      # Called by the withheld session, cookie jar and flash. +key+ is `nil` for a
      # read of the whole input, and +read+ names a read its key does not name.
      def read(input, key = nil, read = nil)
        key = key&.to_s

        report(input, key, read) do
          read ||= key ? "#{input}[#{key.to_sym.inspect}]" : input.to_s
          "`#{read}` was read by a render#{render_name} through ActionController::Renderer " \
            "that was not given #{REQUEST_INPUTS.fetch(input)}. The render is not part of a request, " \
            "and its output may be sent to other users, for example in a Turbo Stream broadcast. " \
            "Pass the values it needs as locals."
        end
      end

      # Called by CurrentAttributes::Isolation, as its +on_dropped_read+, for a
      # read of an attribute that the render's caller had set and the render did
      # not receive.
      def call(current, name)
        read = "#{current.class.name}.#{name}"

        report(:current_attributes, read) do
          "`#{read}` was read by a render#{render_name} through ActionController::Renderer, " \
            "which renders with `Current` attributes of its own, so it read `nil` or the attribute's default. " \
            "Its caller had set `#{read}`, including with a `#{current.class.name}.set` block around the render, " \
            "but the render's output may be sent to other users, for example in a Turbo Stream broadcast. " \
            "Pass the values it needs as locals, for example `locals: { #{name}: ... }`, and read them in place of `#{read}`."
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
              input: input,
              key: key,
              message: yield,
              stack_trace: caller
            )
          end
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
