# frozen_string_literal: true

# :markup: markdown

module ActionController
  class Renderer
    # What one render through the renderer receives, and from where. A render
    # receives inputs from three sources, and from nothing else:
    #
    # * Its locals and assigns, from the render arguments, as given.
    # * Its request, built from the renderer env: a host, HTTPS, a script name,
    #   and a session, cookies or flash only when the env holds them.
    # * Its `Current` attributes. With
    #   `config.action_controller.renderer_isolates_current_attributes`, they
    #   start empty, but for the attributes a framework or library declared with
    #   ActiveSupport::CurrentAttributes::Isolation.carry. Otherwise they are the
    #   caller's.
    #
    # Reads of what a render did not receive, a session, cookies or flash
    # missing from the env, or a `Current` attribute its caller had set, are
    # reported to an UnprovidedInputs, as
    # `config.action_controller.action_on_unprovided_renderer_input` says.
    class Inputs # :nodoc:
      def initialize(controller, env, render_args)
        @controller = controller
        @env = env

        if action = controller.action_on_unprovided_renderer_input
          @unprovided = UnprovidedInputs.new(action, controller, render_args)
        end
      end

      def request
        if @unprovided
          WithholdingRequest.new(@env, @unprovided)
        else
          ActionDispatch::Request.new(@env)
        end
      end

      # Runs the render with the `Current` attributes it receives.
      def rendering(&block)
        if @controller.renderer_isolates_current_attributes
          ActiveSupport::CurrentAttributes::Isolation.run(carry: true, on_dropped_read: @unprovided, &block)
        else
          yield
        end
      end
    end
  end
end
