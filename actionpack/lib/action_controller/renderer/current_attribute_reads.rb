# frozen_string_literal: true

# :markup: markdown

module ActionController
  class Renderer
    # Reports the reads a render makes of ActiveSupport::CurrentAttributes set for
    # the request whose action is being processed, as
    # `config.action_controller.action_on_current_attribute_read_in_renderer` says.
    # One is created for each render made while a controller processes an action.
    class CurrentAttributeReads # :nodoc:
      EVENT = "current_attribute_read_in_renderer.action_controller"

      # The controller processing an action on this thread or fiber, if any. Jobs
      # performed inline during the action, as the inline and test adapters do,
      # run within it and share its `Current` attributes, so their renders are
      # checked too.
      def self.processing_controller
        ActiveSupport::IsolatedExecutionState[:action_controller_processing]
      end

      def initialize(action, processing, renderer_controller, render_args)
        @action = action
        @processing = processing
        @renderer_controller = renderer_controller
        @rendered_name = rendered_name(render_args)
        @opened_after = processing.send(:set_blocks_opened_before_action)
        @instance = nil
        @reported = nil
      end

      def observe(instance, &block)
        @instance = instance
        ActiveSupport::CurrentAttributes.observing_reads(method(:read), &block)
      end

      private
        def read(current, name)
          return if current.provided_attribute?(name, opened_after: @opened_after)

          # Raise on every read, so that rescuing one does not let the next one through.
          raise CurrentAttributeReadError, message(current, name) if @action == :raise
          return unless (@reported ||= Set.new).add?([current.class, name])

          case @action
          when :log
            @renderer_controller.logger&.warn message(current, name)
          when :notify
            ActiveSupport::Notifications.instrument(EVENT,
              attribute: "#{current.class.name}.#{name}",
              template: template,
              controller: @processing,
              message: message(current, name),
              stack_trace: caller
            )
          end
        end

        def message(current, name)
          "`#{current.class.name}.#{name}` was read by `#{template}`, rendered through " \
            "ActionController::Renderer during `#{@processing.class.name}##{@processing.action_name}`, " \
            "which set it for its request. The render's output may be sent to other users, for example " \
            "in a Turbo Stream broadcast, so it must not depend on the request's `#{name}`. Pass the value " \
            "as a local, as in `render partial: ..., locals: { #{name}: ... }`, and read the local in the " \
            "template, or provide it with `#{current.class.name}.set(#{name}: ...) { ... }` around the render."
        end

        # The template file, with its line, whose code made the read, or, when no
        # frame is in a template, what the render's arguments name.
        def template
          template_location || @rendered_name || "the render"
        end

        def template_location
          view_paths = @instance.view_paths.paths.filter_map { |resolver| resolver.try(:path)&.to_s }

          caller_locations.each do |location|
            path = location.path
            if view_path = view_paths.find { |prefix| path.start_with?("#{prefix}/") }
              return "#{path.delete_prefix("#{view_path}/")}:#{location.lineno}"
            end
          end
          nil
        end

        # Read before rendering normalizes the options in place.
        def rendered_name(render_args)
          options = Hash === render_args.last ? render_args.last : {}
          rendered = options[:partial] || options[:template] || options[:action] || render_args.first
          rendered = rendered.to_partial_path if rendered.respond_to?(:to_partial_path)
          rendered.to_s if String === rendered || Symbol === rendered
        end
    end
  end
end
