# frozen_string_literal: true

require "abstract_unit"
require "active_support/current_attributes/test_helper"
require "active_support/log_subscriber/test_helper"

class RendererRequestCurrent < ActiveSupport::CurrentAttributes
  attribute :user, :account
  attribute :tags, default: -> { [] }
end

class RendererCurrentAttributesController < ActionController::Base
  class_attribute :rendering
  class_attribute :around_set, default: false

  before_action { RendererRequestCurrent.user = "david" }
  around_action :set_user_around, if: -> { around_set }

  def index
    render plain: rendering.call
  end

  private
    def set_user_around(&block)
      RendererRequestCurrent.set(user: "around", &block)
    end
end

class RendererCurrentAttributesTest < ActionController::TestCase
  include ActiveSupport::CurrentAttributes::TestHelper

  tests RendererCurrentAttributesController

  PARTIAL = "renderer_current_attributes/current_user"

  setup do
    @logger = ActiveSupport::LogSubscriber::TestHelper::MockLogger.new
  end

  teardown do
    RendererCurrentAttributesController.around_set = false
  end

  test "action_on_current_attribute_read_in_renderer is :log by default" do
    assert_equal :log, ActionController::Base.action_on_current_attribute_read_in_renderer
  end

  test ":raise names the attribute, the template line, the action and the fix" do
    error = assert_raises(ActionView::Template::Error) do
      render_in_action(:raise) { ApplicationController.render(partial: PARTIAL) }
    end

    assert_instance_of ActionController::Renderer::CurrentAttributeReadError, error.cause
    assert_equal "`RendererRequestCurrent.user` was read by `renderer_current_attributes/_current_user.html.erb:2`, " \
      "rendered through ActionController::Renderer during `RendererCurrentAttributesController#index`, which set it " \
      "for its request. The render's output may be sent to other users, for example in a Turbo Stream broadcast, so " \
      "it must not depend on the request's `user`. Pass the value as a local, as in " \
      "`render partial: ..., locals: { user: ... }`, and read the local in the template, or provide it with " \
      "`RendererRequestCurrent.set(user: ...) { ... }` around the render.", error.cause.message
    assert_equal "2", error.line_number
  end

  test ":raise names the inline render when no template file made the read" do
    error = assert_raises(ActionView::Template::Error) do
      render_in_action(:raise) { ApplicationController.render(inline: "<%= RendererRequestCurrent.user %>") }
    end

    assert_match "`RendererRequestCurrent.user` was read by `the render`", error.cause.message
  end

  test ":raise raises again for a read after a rescued one" do
    error = assert_raises(ActionView::Template::Error) do
      render_in_action(:raise) do
        ApplicationController.render(inline: "<%= RendererRequestCurrent.user rescue 'rescued' %>\n<%= RendererRequestCurrent.user %>")
      end
    end

    assert_equal "2", error.line_number
  end

  test ":log renders the request's value and warns once per render and attribute" do
    content = render_in_action(:log) do
      ApplicationController.render(inline: "<%= RendererRequestCurrent.user %><%= RendererRequestCurrent.user %>") +
        ApplicationController.render(partial: PARTIAL)
    end

    assert_equal "daviddavid<h1>Message</h1>\n<p>david</p>\n", content
    warnings = @logger.logged(:warn)
    assert_equal 2, warnings.size
    assert warnings.all? { |warning| warning.start_with?("`RendererRequestCurrent.user` was read by") }
  end

  test ":notify publishes an event per render and attribute" do
    events = capture_notifications("current_attribute_read_in_renderer.action_controller") do
      render_in_action(:notify) { ApplicationController.render(partial: PARTIAL) }
    end

    assert_equal 1, events.size
    payload = events.first.payload
    assert_equal "RendererRequestCurrent.user", payload[:attribute]
    assert_equal "renderer_current_attributes/_current_user.html.erb:2", payload[:template]
    assert_instance_of RendererCurrentAttributesController, payload[:controller]
    assert payload[:stack_trace].any? { |line| line.include?("_current_user.html.erb") }
    assert_empty @logger.logged(:warn)
  end

  test "false renders the request's value without reporting" do
    assert_equal "david", render_in_action(false) { ApplicationController.render(inline: "<%= RendererRequestCurrent.user %>") }
    assert_empty @logger.logged(:warn)
  end

  test "a value passed as a local is not reported" do
    content = render_in_action(:raise) do
      ApplicationController.render(partial: "renderer_current_attributes/user", locals: { user: "recipient" })
    end

    assert_equal "<p>recipient</p>\n", content
  end

  test "a set block opened during the action provides the attributes it names" do
    content = render_in_action(:raise) do
      RendererRequestCurrent.set(user: "recipient") { ApplicationController.render(partial: PARTIAL) }
    end

    assert_equal "<h1>Message</h1>\n<p>recipient</p>\n", content
  end

  test "a set block opened during the action with the request's value provides it" do
    content = render_in_action(:raise) do
      RendererRequestCurrent.set(user: RendererRequestCurrent.user) { ApplicationController.render(partial: PARTIAL) }
    end

    assert_equal "<h1>Message</h1>\n<p>david</p>\n", content
  end

  test "a set block opened in the render provides the attributes it names" do
    content = render_in_action(:raise) do
      ApplicationController.render(inline: "<% RendererRequestCurrent.set(user: 'jane') do %><%= RendererRequestCurrent.user %><% end %>")
    end

    assert_equal "jane", content
  end

  test "a set block opened around the action provides nothing" do
    RendererCurrentAttributesController.around_set = true

    error = assert_raises(ActionView::Template::Error) do
      render_in_action(:raise) { ApplicationController.render(partial: PARTIAL) }
    end

    assert_match "`RendererRequestCurrent.user` was read", error.cause.message
  end

  test "a value the render writes is its own" do
    content = render_in_action(:raise) do
      ApplicationController.render(inline: "<% RendererRequestCurrent.user = 'jane' %><%= RendererRequestCurrent.user %>")
    end

    assert_equal "jane", content
    assert_equal "jane", RendererRequestCurrent.user
  end

  test "attributes at their defaults are not reported" do
    content = render_in_action(:raise) do
      ApplicationController.render(inline: "<%= RendererRequestCurrent.account.inspect %> <%= RendererRequestCurrent.tags.inspect %>")
    end

    assert_equal "nil []", content
  end

  test "reading every attribute reports the ones the request set" do
    error = assert_raises(ActionView::Template::Error) do
      render_in_action(:raise) { ApplicationController.render(inline: "<%= RendererRequestCurrent.attributes %>") }
    end

    assert_match "`RendererRequestCurrent.user` was read", error.cause.message
  end

  test "renders made outside of an action are not checked" do
    ActionController::Base.with(action_on_current_attribute_read_in_renderer: :raise) do
      RendererRequestCurrent.user = "david"
      assert_equal "david", ApplicationController.render(inline: "<%= RendererRequestCurrent.user %>")

      RendererCurrentAttributesController.rendering = -> { "" }
      get :index
      RendererRequestCurrent.user = "david"
      assert_equal "david", ApplicationController.render(inline: "<%= RendererRequestCurrent.user %>")
    end
  end

  test "the attributes are left as the render found them" do
    render_in_action(:log) { ApplicationController.render(partial: PARTIAL) }

    assert_equal "david", RendererRequestCurrent.user
    assert_instance_of Hash, RendererRequestCurrent.instance.instance_variable_get(:@attributes)
    refute_kind_of ActiveSupport::CurrentAttributes::ObservedAttributes, RendererRequestCurrent.instance.instance_variable_get(:@attributes)
  end

  private
    def render_in_action(action, &rendering)
      RendererCurrentAttributesController.rendering = rendering

      ActionController::Base.with(action_on_current_attribute_read_in_renderer: action) do
        ApplicationController.with(logger: @logger) do
          get :index
        end
      end

      @response.body
    end
end
