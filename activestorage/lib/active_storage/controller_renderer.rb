# frozen_string_literal: true

module ActiveStorage
  # Prepended into ActionController::Renderer so blob, variant, and preview URLs
  # generated during a render can be built outside a request, such as in a job,
  # from the renderer's request host, protocol, and port.
  #
  # +config.active_storage.renderer_url_options+ chooses the source. With
  # +:caller+, ActiveStorage::Current.url_options already set, by the request
  # being processed on the current thread or by the application, are kept, and
  # the renderer's request fills them only when unset. With +:renderer+, the
  # renderer's request is used for the duration of the render.
  module ControllerRenderer # :nodoc:
    def render(...)
      with_renderer_url_options { super }
    end

    def render_to_string(...)
      with_renderer_url_options { super }
    end

    private
      def with_renderer_url_options(&)
        if ActiveStorage.renderer_url_options == :renderer || ActiveStorage::Current.url_options.blank?
          ActiveStorage::Current.set(url_options: request_url_options, &)
        else
          yield
        end
      end

      def request_url_options
        request = ActionDispatch::Request.new(env_for_request)
        { protocol: request.protocol, host: request.host, port: request.port }
      end
  end
end
