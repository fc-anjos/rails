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
    # * Its per-thread state. With
    #   `config.action_controller.renderer_isolates_execution_state`, it runs on
    #   an ActiveSupport::IsolatedExecutionState store of its own, so
    #   `Current` attributes, `thread_mattr_accessor` values and everything else
    #   Rails keeps per thread or fiber start empty, but for what is registered
    #   with ActiveSupport::CarriedState, which is captured in the caller and
    #   restored around the render. Otherwise it is the caller's.
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

      # Runs the render with the per-thread state it receives.
      def rendering(&block)
        if @controller.renderer_isolates_execution_state
          carried = ActiveSupport::CarriedState.capture
          rendering = false

          # Reads made by the restorers, such as Current.set reading the value
          # it puts back, are not the render's, so only the render's are reported.
          if @unprovided
            on_dropped_read = ->(current, name) { @unprovided.call(current, name) if rendering }
          end

          ActiveSupport::CurrentAttributes::Isolation.run(on_dropped_read: on_dropped_read) do
            ActiveSupport::IsolatedExecutionState.isolated do
              ActiveSupport::CarriedState.restore(carried) do
                rendering = true
                yield
              ensure
                rendering = false
              end
            end
          end
        else
          yield
        end
      end
    end
  end
end
