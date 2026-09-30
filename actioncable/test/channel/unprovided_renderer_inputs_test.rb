# frozen_string_literal: true

require "test_helper"
require "stubs/test_server"
require "action_controller"

class ActionCable::Channel::UnprovidedRendererInputsTest < ActionCable::TestCase
  class Current < ActiveSupport::CurrentAttributes
    attribute :user
  end

  class RenderingController < ActionController::Base
  end

  module Renders
    mattr_accessor :renders, default: []
    mattr_accessor :errors, default: []

    private
      def render_user
        renders << RenderingController.render(inline: "<%= #{Current.name}.user %>")
      rescue ActionView::Template::Error => error
        raise unless ActionController::Renderer::UnprovidedInputError === error.cause
        renders << "unprovided"
        errors << error.message
      end
  end

  class Connection < ActionCable::Connection::Base
    include Renders

    around_command :set_current_user

    private
      def set_current_user(&)
        Current.set(user: "david", &)
      end
  end

  class RenderBeforeYieldConnection < Connection
    private
      def set_current_user
        Current.set(user: "david") do
          render_user
          yield
        end
      end
  end

  class BeforeCommandConnection < Connection
    before_command :render_user_in_set_block

    private
      def render_user_in_set_block
        Current.set(user: "jane") { render_user }
      end
  end

  class RenderBeforeCommandConnection < Connection
    before_command :render_user
  end

  class HaltingInSetBlockConnection < Connection
    before_command do
      Current.set(user: "jane") do
        render_user
        throw :abort
      end
    end
  end

  class ChatChannel < ActionCable::Channel::Base
    include Renders

    def subscribed = render_user
    def unsubscribed = render_user
    def speak = render_user

    def speak_in_set_block
      Current.set(user: "jane") { render_user }
    end
  end

  class SilentChannel < ActionCable::Channel::Base
    include Renders

    before_subscribe :render_user_in_set_block

    private
      def render_user_in_set_block
        Current.set(user: "jane") { render_user }
      end
  end

  class RenderBeforeSubscribeChannel < ActionCable::Channel::Base
    include Renders

    before_subscribe :render_user
  end

  setup do
    Renders.renders = []
    Renders.errors = []
    @server = TestServer.new
    @env = Rack::MockRequest.env_for "/test", "HTTP_HOST" => "localhost", "HTTP_CONNECTION" => "upgrade", "HTTP_UPGRADE" => "websocket"
  end

  teardown do
    Current.reset
  end

  test "an around_command's set block does not provide its attributes to a render in a channel action" do
    connection = connect

    subscribe connection
    perform connection, "speak"

    assert_equal ["unprovided", "unprovided"], Renders.renders
    assert_match "The render is not part of the channel action `#{ChatChannel.name}#subscribed`", Renders.errors.first
    assert_equal "`#{Current.name}.user` was read by a render through ActionController::Renderer, " \
      "and no `#{Current.name}.set` block opened during the action provides it. " \
      "The render is not part of the channel action `#{ChatChannel.name}#speak`, during which the attribute was set, " \
      "and its output may be sent to other users, for example in a Turbo Stream broadcast. " \
      "Pass the values it needs as locals, or provide it with `#{Current.name}.set(user: ...) { ... }`.", Renders.errors.last
  end

  test "a set block opened in a channel action provides its attributes" do
    connection = connect

    subscribe connection
    perform connection, "speak_in_set_block"

    assert_equal ["unprovided", "jane"], Renders.renders
  end

  test "an around_command's set block provides its attributes to renders made before the channel calls the action method" do
    subscribe connect(RenderBeforeYieldConnection)
    assert_equal ["david", "unprovided"], Renders.renders

    Renders.renders = []
    subscribe connect(RenderBeforeCommandConnection)
    assert_equal ["david", "unprovided"], Renders.renders

    Renders.renders = []
    subscribe connect, RenderBeforeSubscribeChannel
    assert_equal ["david"], Renders.renders
  end

  test "a set block a before_command or before_subscribe callback opens provides its attributes" do
    connection = connect(BeforeCommandConnection)
    subscribe connection
    perform connection, "speak_in_set_block"
    assert_equal ["jane", "unprovided", "jane", "jane"], Renders.renders

    Renders.renders = []
    subscribe connect(HaltingInSetBlockConnection)
    assert_equal ["jane"], Renders.renders

    Renders.renders = []
    subscribe connect, SilentChannel
    assert_equal ["jane"], Renders.renders
  end

  test "a channel unsubscribed as the connection closes is checked as its own command" do
    connection = connect
    subscribe connection
    Renders.renders = []

    Current.set(user: "david") do
      with_unprovided_renderer_input_raising { connection.handle_close }
    end

    assert_equal ["unprovided"], Renders.renders
    assert_match "The render is not part of the channel action `#{ChatChannel.name}#unsubscribed`", Renders.errors.last
  end

  private
    def connect(connection_class = Connection)
      connection_class.new(@server, ActionCable::Server::Socket.new(@server, @env))
    end

    def identifier(channel = ChatChannel)
      { channel: channel.name }.to_json
    end

    def subscribe(connection, channel = ChatChannel)
      with_unprovided_renderer_input_raising do
        connection.handle_channel_command("command" => "subscribe", "identifier" => identifier(channel))
      end
    end

    def perform(connection, action, channel = ChatChannel)
      with_unprovided_renderer_input_raising do
        connection.handle_channel_command("command" => "message", "identifier" => identifier(channel), "data" => { action: action }.to_json)
      end
    end

    def with_unprovided_renderer_input_raising(&)
      ActionController::Base.with(action_on_unprovided_renderer_input: :raise, &)
    end
end

class ActionCable::Channel::UnprovidedRendererInputsTestCaseTest < ActionCable::Channel::TestCase
  Current = ActionCable::Channel::UnprovidedRendererInputsTest::Current
  Renders = ActionCable::Channel::UnprovidedRendererInputsTest::Renders

  tests ActionCable::Channel::UnprovidedRendererInputsTest::ChatChannel

  setup do
    Renders.renders = []
  end

  teardown do
    Current.reset
  end

  test "subscribe and perform check renders against the Current attributes the test assigns" do
    Current.user = "david"

    ActionController::Base.with(action_on_unprovided_renderer_input: :raise) do
      subscribe
      perform :speak
      perform :speak_in_set_block
    end

    assert_equal ["unprovided", "unprovided", "jane"], Renders.renders
  end
end
