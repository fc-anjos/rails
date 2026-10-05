# frozen_string_literal: true

require "test_helper"
require "stubs/test_server"
require "action_controller"

class ActionCable::Channel::RendererIsolationTest < ActionCable::TestCase
  class Current < ActiveSupport::CurrentAttributes
    attribute :user
  end

  class RenderingController < ActionController::Base
  end

  class Connection < ActionCable::Connection::Base
    around_command :set_current_user

    private
      def set_current_user(&)
        Current.set(user: "david", &)
      end
  end

  class ChatChannel < ActionCable::Channel::Base
    mattr_accessor :renders, default: []

    def speak
      renders << render_user
    end

    def speak_to_everyone
      renders << RenderingController.render(inline: "<%= user.inspect %>", locals: { user: "everyone" })
    end

    private
      def render_user
        RenderingController.render(inline: "<%= #{Current.name}.user.inspect %>")
      rescue ActionView::Template::Error => error
        raise unless ActionController::Renderer::UnprovidedInputError === error.cause
        "unprovided"
      end
  end

  setup do
    ChatChannel.renders = []
    @server = TestServer.new
    @env = Rack::MockRequest.env_for "/test", "HTTP_HOST" => "localhost", "HTTP_CONNECTION" => "upgrade", "HTTP_UPGRADE" => "websocket"
  end

  teardown do
    Current.reset
  end

  test "without isolation, a render in a channel action reads the command's Current attributes" do
    perform "speak", isolates: false, input: false

    assert_equal ["&quot;david&quot;"], ChatChannel.renders
  end

  test "with isolation, a render in a channel action does not read the command's Current attributes" do
    perform "speak", isolates: true, input: false

    assert_equal ["nil"], ChatChannel.renders
  end

  test "with isolation, :raise reports the read of an attribute the command had set" do
    perform "speak", isolates: true, input: :raise

    assert_equal ["unprovided"], ChatChannel.renders
  end

  test "with isolation, a render given its values as locals reads them, unreported" do
    perform "speak_to_everyone", isolates: true, input: :raise

    assert_equal ["&quot;everyone&quot;"], ChatChannel.renders
  end

  private
    def perform(action, isolates:, input:)
      connection = Connection.new(@server, ActionCable::Server::Socket.new(@server, @env))
      identifier = { channel: ChatChannel.name }.to_json

      ActionController::Base.with(renderer_isolates_current_attributes: isolates, action_on_unprovided_renderer_input: input) do
        connection.handle_channel_command("command" => "subscribe", "identifier" => identifier)
        connection.handle_channel_command("command" => "message", "identifier" => identifier, "data" => { action: action }.to_json)
      end
    end
end
