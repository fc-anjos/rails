# frozen_string_literal: true

require "test_helper"

class ActionText::RendererRenderTest < ActionDispatch::IntegrationTest
  test "renders attachments with the renderer's request instead of the current controller's" do
    blob = create_file_blob(filename: "racecar.jpg", content_type: "image/jpeg")
    message = Message.create!(content: ActionText::Content.new.append_attachables(blob))
    current_request_renderer = MessagesController.renderer.new(http_host: "requester.example")

    html = ActionText::Content.with_renderer(current_request_renderer) do
      MessagesController.renderer.new(http_host: "broadcast.example").render(inline: "<%= message.content %>", locals: { message: message })
    end

    assert_match %r"//broadcast\.example/.+/racecar", html
    assert_no_match %r"requester\.example", html
  end

  test "restores the current renderer after rendering" do
    current_request_renderer = MessagesController.renderer.new(http_host: "requester.example")

    ActionText::Content.with_renderer(current_request_renderer) do
      MessagesController.render(inline: "")
      assert_same current_request_renderer, ActionText::Content.renderer
    end
  end
end
