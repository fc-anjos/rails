# frozen_string_literal: true

# :markup: markdown

module ActionText
  # Prepended into ActionController::Renderer so content rendered outside a
  # request cycle, such as a broadcast rendered once for many viewers, renders
  # its attachments through the same renderer instead of through whichever
  # controller is handling the current request. Attachments therefore see the
  # renderer's application helpers and its neutral request, never the live
  # request's host, cookies, or controller state.
  module ControllerRenderer # :nodoc:
    def render(...)
      ActionText::Content.with_renderer(self) { super }
    end

    def render_to_string(...)
      ActionText::Content.with_renderer(self) { super }
    end
  end
end
