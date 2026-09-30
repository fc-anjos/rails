# frozen_string_literal: true

require "abstract_unit"
require "test_renderable"
require "active_support/key_generator"
require "active_support/messages/rotation_configuration"
require "active_support/current_attributes/test_helper"
require "active_support/execution_context/test_helper"
require "active_support/log_subscriber/test_helper"

class RendererTest < ActiveSupport::TestCase
  include ActiveSupport::ExecutionContext::TestHelper

  test "action controller base has a renderer" do
    assert ActionController::Base.renderer
  end

  test "creating with a controller" do
    controller = CommentsController
    renderer   = ActionController::Renderer.for controller

    assert_equal controller, renderer.controller
  end

  test "creating from a controller" do
    controller = AccountsController
    renderer   = controller.renderer

    assert_equal controller, renderer.controller
  end

  test "creating with new defaults" do
    renderer = ApplicationController.renderer

    new_defaults = { https: true }
    new_renderer = renderer.with_defaults(new_defaults).new
    content = new_renderer.render(inline: "<%= request.ssl? %>")

    assert_equal "true", content
  end

  test "rendering with a class renderer" do
    renderer = ApplicationController.renderer
    content  = renderer.render template: "ruby_template"

    assert_equal "Hello from Ruby code", content
  end

  test "rendering with an instance renderer" do
    renderer = ApplicationController.renderer.new
    content  = renderer.render template: "test/hello_world"

    assert_equal "Hello world!", content
  end

  test "rendering with a controller class" do
    assert_equal "Hello world!", ApplicationController.render("test/hello_world")
  end

  test "rendering with locals" do
    renderer = ApplicationController.renderer
    content  = renderer.render template: "test/render_file_with_locals",
                               locals: { secret: "bar" }

    assert_equal "The secret is bar\n", content
  end

  test "rendering with assigns" do
    renderer = ApplicationController.renderer
    content  = renderer.render template: "test/render_file_with_ivar",
                               assigns: { secret: "foo" }

    assert_equal "The secret is foo\n", content
  end

  test "render a renderable object" do
    renderer = ApplicationController.renderer

    assert_equal(
      %(Hello, World!),
      renderer.render(TestRenderable.new)
    )
    assert_equal(
      %(Hello, World!),
      renderer.render(renderable: TestRenderable.new)
    )
    assert_equal(
      %(Hello, Local!),
      renderer.render(TestRenderable.new, name: "Local")
    )
    assert_equal(
      %(Hello, Local!),
      renderer.render(renderable: TestRenderable.new, locals: { name: "Local" })
    )
  end

  test "render a renderable object with block" do
    renderer = ApplicationController.renderer

    assert_equal(
      %(Hello, Block!),
      renderer.render(TestRenderable.new) { "Hello, Block!" }
    )
    assert_equal(
      %(Hello, Block!),
      renderer.render(renderable: TestRenderable.new) { "Hello, Block!" }
    )
  end

  test "rendering with custom env" do
    renderer = ApplicationController.renderer.new method: "post"
    content  = renderer.render inline: "<%= request.post? %>"

    assert_equal "true", content
  end

  test "rendering with custom env using a key that is not in RACK_KEY_TRANSLATION" do
    value    = "warden is here"
    renderer = ApplicationController.renderer.new warden: value
    content  = renderer.render inline: "<%= request.env['warden'] %>"

    assert_equal value, content
  end

  test "reads of a session, cookies and flash a render was not given publish read_input events" do
    reads = capture_reads do
      render(inline: "<%= session[:user_id].inspect %> <%= cookies[:theme].inspect %> <%= flash[:notice].inspect %>")
    end

    assert_equal [[:session, "user_id"], [:cookies, "theme"], [:flash, "notice"]], reads
  end

  test "rendering with defaults" do
    renderer = ApplicationController.renderer.new https: true
    content = renderer.render inline: "<%= request.ssl? %>"

    assert_equal "true", content
  end

  test "same defaults from the same controller" do
    renderer_defaults = ->(controller) { controller.renderer.defaults }

    assert_equal renderer_defaults[AccountsController], renderer_defaults[AccountsController]
    assert_equal renderer_defaults[AccountsController], renderer_defaults[CommentsController]
  end

  test "rendering with different formats" do
    html = "Hello world!"
    xml  = "<p>Hello world!</p>\n"

    assert_equal html, render("respond_to/using_defaults")
    assert_equal xml,  render("respond_to/using_defaults", formats: :xml)
  end

  test "rendering with helpers" do
    assert_equal "<p>1\n<br />2</p>", render(inline: '<%= simple_format "1\n2" %>')
  end

  test "rendering with user specified defaults" do
    renderer.defaults.merge!(hello: "hello", https: true)
    content = renderer.new.render inline: "<%= request.ssl? %>"

    assert_equal "true", content
  end

  test "return valid asset URL with defaults" do
    renderer = ApplicationController.renderer
    content  = renderer.render inline: "<%= asset_url 'asset.jpg' %>"

    assert_equal "http://example.org/asset.jpg", content
  end

  test "return valid asset URL when https is true" do
    renderer = ApplicationController.renderer.new https: true
    content  = renderer.render inline: "<%= asset_url 'asset.jpg' %>"

    assert_equal "https://example.org/asset.jpg", content
  end

  test "uses default_url_options from the controller's routes when env[:http_host] not specified" do
    with_default_url_options(
      protocol: "https",
      host: "foo.example.com",
      port: 9001,
      script_name: "/bar",
    ) do
      assert_equal "https://foo.example.com:9001/bar/posts", render_url_for(controller: :posts)
    end
  end

  test "uses config.force_ssl when env[:http_host] not specified" do
    with_default_url_options(host: "foo.example.com") do
      with_force_ssl do
        assert_equal "https://foo.example.com/posts", render_url_for(controller: :posts)
      end
    end
  end

  test "can specify env[:https] when using default_url_options" do
    with_default_url_options(host: "foo.example.com") do
      @renderer = renderer.new(https: true)
      assert_equal "https://foo.example.com/posts", render_url_for(controller: :posts)
    end
  end

  test "env[:https] overrides default_url_options[:protocol]" do
    with_default_url_options(host: "foo.example.com", protocol: "https") do
      @renderer = renderer.new(https: false)
      assert_equal "http://foo.example.com/posts", render_url_for(controller: :posts)
    end
  end

  test "can specify env[:script_name] when using default_url_options" do
    with_default_url_options(host: "foo.example.com") do
      @renderer = renderer.new(script_name: "/bar")
      assert_equal "http://foo.example.com/bar/posts", render_url_for(controller: :posts)
    end
  end

  test "env[:script_name] overrides default_url_options[:script_name]" do
    with_default_url_options(host: "foo.example.com", script_name: "/bar") do
      @renderer = renderer.new(script_name: "")
      assert_equal "http://foo.example.com/posts", render_url_for(controller: :posts)
    end
  end

  INPUT_READS = "<%= session[:user_id].inspect %> <%= session.to_hash.inspect %> <%= cookies[:theme].inspect %> " \
    "<%= flash[:notice].inspect %> <%= flash.to_hash.inspect %> <%= form_authenticity_token.present? %>"
  INPUT_READS_WITHOUT_INPUTS = "nil {} nil nil {} true"

  test "action_on_unprovided_renderer_input is :log by default" do
    assert_equal :log, ActionController::Base.action_on_unprovided_renderer_input
  end

  test "false reads nil from a session, cookies or flash the render was not given" do
    with_unprovided_renderer_input(false) do
      assert_equal INPUT_READS_WITHOUT_INPUTS, render(inline: INPUT_READS)
      assert_empty @logger.logged(:warn)
    end
  end

  test ":log reads what false reads, and warns once per render and input" do
    with_unprovided_renderer_input(:log) do
      content = render(inline: "#{INPUT_READS} <%= session[:user_id].inspect %>")
      assert_equal "#{INPUT_READS_WITHOUT_INPUTS} nil", content

      assert_equal [
        "`session[:user_id]` was read by a render through ActionController::Renderer that was not given a session.",
        "`session` was read by a render through ActionController::Renderer that was not given a session.",
        "`cookies[:theme]` was read by a render through ActionController::Renderer that was not given cookies.",
        "`flash[:notice]` was read by a render through ActionController::Renderer that was not given a flash.",
        "`flash` was read by a render through ActionController::Renderer that was not given a flash.",
        "`session[:_csrf_token]` was read by a render through ActionController::Renderer that was not given a session.",
      ], @logger.logged(:warn).map { |warning| warning[/\A.*?\./] }
      assert_match "The render is not part of a request, and its output may be sent to other users, " \
        "for example in a Turbo Stream broadcast. Pass the values it needs as locals, or read them from " \
        "`Current` attributes set with a `Current.set` block around the render.", @logger.logged(:warn).first

      render(inline: "<%= session[:user_id].inspect %>")
      assert_equal 7, @logger.logged(:warn).size
    end
  end

  test ":notify reads what false reads, and publishes an event per render and input" do
    with_unprovided_renderer_input(:notify) do
      content = nil
      events = capture_notifications("unprovided_renderer_input.action_controller") do
        content = render(inline: "<%= session[:user_id].inspect %>\n<%= session[:user_id].inspect %> <%= cookies[:theme].inspect %> <%= flash.to_hash.inspect %>")
      end

      assert_equal "nil\nnil nil {}", content
      assert_equal [[:session, "user_id"], [:cookies, "theme"], [:flash, nil]], events.map { |event| event.payload.values_at(:input, :key) }

      payload = events.first.payload
      assert_nil payload[:controller]
      assert_match "`session[:user_id]` was read by a render through ActionController::Renderer that was not given a session.", payload[:message]
      assert payload[:stack_trace].any? { |line| line.include?("inline template") }
      assert_empty @logger.logged(:warn)
    end
  end

  test ":raise raises on keyed session reads, naming the key" do
    with_unprovided_renderer_input(:raise) do
      [
        "session[:user_id]", 'session["user_id"]', "session.fetch(:user_id, nil)", "session.dig(:user_id, :id)",
        "session.has_key?(:user_id)", "session.key?(:user_id)", "session.include?(:user_id)"
      ].each do |read|
        error = assert_unprovided_input { render(inline: "<%= #{read} %>") }
        assert_match "`session[:user_id]` was read by a render through ActionController::Renderer that was not given a session.", error.message
        assert_match "Pass the values it needs as locals, or read them from `Current` attributes", error.message
      end
    end
  end

  test ":raise raises on reads of the whole session and its id" do
    with_unprovided_renderer_input(:raise) do
      ["session.to_hash", "session.to_h", "session.keys", "session.values", "session.empty?", "session.each { }"].each do |read|
        error = assert_unprovided_input { render(inline: "<%= #{read} %>") }
        assert_match "`session` was read by a render", error.message
      end

      ["session.id", "session.id_was"].each do |read|
        error = assert_unprovided_input { render(inline: "<%= #{read} %>") }
        assert_match "`session.id` was read by a render", error.message
      end
    end
  end

  test "session writes raise as for a disabled session, whatever the setting" do
    [false, :log, :raise].each do |action|
      with_unprovided_renderer_input(action) do
        error = assert_raises(ActionView::Template::Error) { render(inline: "<% session[:user_id] = 1 %>") }
        assert_instance_of ActionDispatch::Http::Session::DisabledSessionError, error.cause
      end
    end
  end

  test ":raise raises at the template line of a helper method reading the session" do
    with_unprovided_renderer_input(:raise) do
      error = assert_unprovided_input do
        RendererInputsController.render(inline: "<p>\n<%= current_user_id %>\n</p>")
      end

      assert_match "`session[:user_id]` was read", error.message
      assert_equal "2", error.line_number
    end
  end

  test ":raise raises on cookie reads, naming the cookie" do
    with_unprovided_renderer_input(:raise) do
      ["cookies[:user_id]", 'cookies["user_id"]', "cookies.fetch(:user_id, nil)", "cookies.key?(:user_id)", "cookies.has_key?(:user_id)"].each do |read|
        error = assert_unprovided_input { render(inline: "<%= #{read} %>") }
        assert_match "`cookies[:user_id]` was read by a render through ActionController::Renderer that was not given cookies.", error.message
      end

      ["cookies.to_hash", "cookies.each { }", "cookies.to_a"].each do |read|
        error = assert_unprovided_input { render(inline: "<%= #{read} %>") }
        assert_match "`cookies` was read by a render", error.message
      end
    end
  end

  SIGNED_AND_ENCRYPTED_READS = {
    "cookies.signed[:user_id]" => "cookies.signed",
    "cookies.encrypted[:user_id]" => "cookies.encrypted",
    "cookies.signed_or_encrypted[:user_id]" => "cookies.signed",
    "cookies.permanent.signed[:user_id]" => "cookies.permanent.signed",
    "cookies.permanent.encrypted[:user_id]" => "cookies.permanent.encrypted",
  }

  test "signed and encrypted cookie reads raise NoMethodError without a key generator, as with false" do
    with_unprovided_renderer_input(false) do
      SIGNED_AND_ENCRYPTED_READS.each_key do |read|
        error = assert_raises(ActionView::Template::Error) { render(inline: "<%= #{read} %>") }
        assert_instance_of NoMethodError, error.cause
      end
    end
    assert_empty @logger.logged(:warn)
  end

  test ":log warns of signed and encrypted cookie reads before they raise NoMethodError, as with false" do
    with_unprovided_renderer_input(:log) do
      SIGNED_AND_ENCRYPTED_READS.each do |read, jar|
        error = assert_raises(ActionView::Template::Error) { render(inline: "<%= #{read} %>") }
        assert_instance_of NoMethodError, error.cause
        assert_match "`#{jar}` was read by a render through ActionController::Renderer that was not given cookies.", @logger.logged(:warn).last
      end
    end
    assert_equal SIGNED_AND_ENCRYPTED_READS.size, @logger.logged(:warn).size
  end

  test ":notify publishes signed and encrypted cookie reads before they raise NoMethodError" do
    with_unprovided_renderer_input(:notify) do
      events = capture_notifications("unprovided_renderer_input.action_controller") do
        error = assert_raises(ActionView::Template::Error) { render(inline: "<%= cookies.encrypted[:user_id] %>") }
        assert_instance_of NoMethodError, error.cause
      end

      assert_equal [[:cookies, nil]], events.map { |event| event.payload.values_at(:input, :key) }
      assert_match "`cookies.encrypted` was read by a render", events.first.payload[:message]
    end
  end

  test ":raise raises on signed and encrypted cookie reads, naming the jar" do
    with_unprovided_renderer_input(:raise) do
      SIGNED_AND_ENCRYPTED_READS.each do |read, jar|
        error = assert_unprovided_input { render(inline: "<%= #{read} %>") }
        assert_match "`#{jar}` was read by a render through ActionController::Renderer that was not given cookies.", error.message
      end
    end
  end

  test "signed and encrypted cookie reads go through the cookie jar when the env carries a key generator" do
    with_unprovided_renderer_input(:raise) do
      keyed_renderer = ApplicationController.renderer.new(cookie_settings_env)

      ["cookies.signed[:user_id]", "cookies.encrypted[:user_id]", "cookies.permanent.signed[:user_id]"].each do |read|
        error = assert_unprovided_input { keyed_renderer.render(inline: "<%= #{read} %>") }
        assert_match "`cookies[:user_id]` was read by a render", error.message
      end
    end
  end

  test ":raise raises on flash reads" do
    with_unprovided_renderer_input(:raise) do
      ["flash[:notice]", "flash.notice", "flash.now[:notice]", "flash.key?(:notice)"].each do |read|
        error = assert_unprovided_input { render(inline: "<%= #{read} %>") }
        assert_match "`flash[:notice]` was read by a render through ActionController::Renderer that was not given a flash.", error.message
      end

      error = assert_unprovided_input { render(inline: "<%= flash.alert %>") }
      assert_match "`flash[:alert]` was read", error.message

      ["flash.to_hash", "flash.keys", "flash.empty?", "flash.present?", "flash.each { }"].each do |read|
        error = assert_unprovided_input { render(inline: "<%= #{read} %>") }
        assert_match "`flash` was read by a render", error.message
      end
    end
  end

  test "the cookies and flash messages a render sets are its own" do
    writes = "<% cookies[:theme] = 'dark' %><% cookies.signed[:user_id] = 45 %><% flash[:notice] = 'Saved' %><% flash.now[:alert] = 'Late' %>"
    reads = "<%= cookies[:theme] %> <%= cookies.fetch(:theme) %> <%= cookies.key?(:theme) %> <%= cookies.signed[:user_id] %> " \
      "<%= flash[:notice] %> <%= flash.alert %> <%= flash.key?(:notice) %>"

    [false, :log, :raise].each do |action|
      with_unprovided_renderer_input(action) do
        assert_equal "dark dark true 45 Saved Late true", ApplicationController.renderer.new(cookie_settings_env).render(inline: writes + reads)
      end
    end
    assert_empty @logger.logged(:warn)

    with_unprovided_renderer_input(:raise) do
      error = assert_unprovided_input { render(inline: "<% cookies[:theme] = 'dark' %><%= cookies[:user_id] %>") }
      assert_match "`cookies[:user_id]` was read", error.message

      error = assert_unprovided_input { render(inline: "<% flash[:alert] = 'Late' %><%= flash[:notice] %>") }
      assert_match "`flash[:notice]` was read", error.message
    end
  end

  test "forms and CSRF meta tags render without a token, whatever the setting" do
    [false, :log, :raise].each do |action|
      with_unprovided_renderer_input(action) do
        content = render(inline: "<%= form_with(url: '/messages') { } %><%= button_to 'Delete', '/messages/1' %><%= csrf_meta_tags %><%= protect_against_forgery? %>")

        assert_match "<form", content
        assert_no_match "authenticity_token", content
        assert_no_match "csrf-token", content
        assert content.end_with?("false")
      end
    end
    assert_empty @logger.logged(:warn)
  end

  test ":raise raises on form_authenticity_token" do
    with_unprovided_renderer_input(:raise) do
      error = assert_unprovided_input { render(inline: "<%= form_authenticity_token %>") }
      assert_match "`session[:_csrf_token]` was read", error.message
    end
  end

  test "a render reads a session passed in the env, and its flash, without reporting them" do
    with_unprovided_renderer_input(:raise) do
      flash = { "discard" => [], "flashes" => { "notice" => "Saved" } }
      content = renderer.new("rack.session" => { user_id: 45, "flash" => flash })
        .render(inline: "<%= session[:user_id] %> <%= flash[:notice] %>")
      assert_equal "45 Saved", content

      content = renderer.new("rack.session" => {}).render(inline: "<%= session[:user_id].inspect %> <%= flash.to_hash.inspect %>")
      assert_equal "nil {}", content
    end
  end

  test "a render reads cookies passed in the env without reporting them" do
    with_unprovided_renderer_input(:raise) do
      cookie = cookie_header do |jar|
        jar[:theme] = "dark"
        jar.signed[:user_id] = 45
        jar.encrypted[:account_id] = 12
      end

      content = renderer.new(cookie_settings_env.merge("HTTP_COOKIE" => cookie))
        .render(inline: "<%= cookies[:theme] %> <%= cookies.signed[:user_id] %> <%= cookies.encrypted[:account_id] %> <%= cookies[:missing].inspect %>")
      assert_equal "dark 45 12 nil", content

      content = renderer.new("HTTP_COOKIE" => cookie).render(inline: "<%= cookies[:theme] %>")
      assert_equal "dark", content
    end
  end

  test "a render reads a flash passed in the env without reporting it" do
    with_unprovided_renderer_input(:raise) do
      flash = ActionDispatch::Flash::FlashHash.new(notice: "Saved")
      content = renderer.new(ActionDispatch::Flash::KEY => flash).render(inline: "<%= flash[:notice] %>")

      assert_equal "Saved", content
    end
  end

  test "the withheld session, cookies and flash are created when a render first uses them" do
    with_unprovided_renderer_input(:log) do
      created = "<%= request.has_header?('rack.session') %> <%= request.have_cookie_jar? %> <%= request.has_header?(ActionDispatch::Flash::KEY) %>"

      assert_equal "false false false", render(inline: created)
      assert_equal "true true true", render(inline: "<% session.enabled? %><% cookies %><% flash %>#{created}")
      assert_empty @logger.logged(:warn)
    end
  end

  test "an ActionController::API renderer renders whatever the setting" do
    [false, :log, :raise].each do |action|
      with_unprovided_renderer_input(action) do
        assert_equal "hi", Class.new(ActionController::API).render(plain: "hi")
      end
    end
  end

  private
    def renderer
      @renderer ||= ApplicationController.renderer.new
    end

    def with_unprovided_renderer_input(action, &block)
      @logger ||= ActiveSupport::LogSubscriber::TestHelper::MockLogger.new

      ActionController::Base.with(action_on_unprovided_renderer_input: action) do
        ApplicationController.with(logger: @logger, &block)
      end
    end

    def assert_unprovided_input(&block)
      error = assert_raises(ActionView::Template::Error, &block)
      assert_instance_of ActionController::Renderer::UnprovidedInputError, error.cause
      error
    end

    # The cookie settings a request to an application carries, which a render is
    # not given unless they are passed in its env.
    def cookie_settings_env
      @cookie_settings_env ||= {
        "action_dispatch.key_generator" => ActiveSupport::KeyGenerator.new("b3c631c314c0bbca50c1b2843150fe33", iterations: 2),
        "action_dispatch.cookies_rotations" => ActiveSupport::Messages::RotationConfiguration.new,
        "action_dispatch.signed_cookie_salt" => "signed cookie",
        "action_dispatch.encrypted_cookie_salt" => "encrypted cookie",
        "action_dispatch.encrypted_signed_cookie_salt" => "signed encrypted cookie",
        "action_dispatch.authenticated_encrypted_cookie_salt" => "authenticated encrypted cookie",
        "action_dispatch.use_authenticated_cookie_encryption" => true,
      }
    end

    def cookie_header
      jar = ActionDispatch::Request.new(cookie_settings_env.dup).cookie_jar
      yield jar
      jar.to_hash.map { |name, value| "#{name}=#{Rack::Utils.escape(value)}" }.join("; ")
    end

    def render(...)
      renderer.render(...)
    end

    def render_url_for(*args)
      render inline: "<%= full_url_for(*#{args.inspect}) %>"
    end

    def with_default_url_options(default_url_options)
      original_default_url_options = renderer.controller._routes.default_url_options
      renderer.controller._routes.default_url_options = default_url_options
      yield
    ensure
      renderer.controller._routes.default_url_options = original_default_url_options
      renderer.controller._routes.default_env # refresh
    end

    def with_force_ssl(force_ssl = true)
      # In a real app, an initializer will set `URL.secure_protocol = app.config.force_ssl`.
      original_secure_protocol = ActionDispatch::Http::URL.secure_protocol
      ActionDispatch::Http::URL.secure_protocol = force_ssl
      yield
    ensure
      ActionDispatch::Http::URL.secure_protocol = original_secure_protocol
    end
end

class RendererInputsController < ActionController::Base
  helper_method :current_user_id

  private
    def current_user_id
      session[:user_id]
    end
end

class RendererCurrent < ActiveSupport::CurrentAttributes
  attribute :user, :account
  attribute :tags, default: -> { [] }

  class_attribute :resets_count, default: 0
  resets { self.class.resets_count += 1 }
end

class RendererUntouchedCurrent < ActiveSupport::CurrentAttributes
  attribute :user
end

class RendererCurrentAttributesController < ActionController::Base
  class_attribute :rendering

  def index
    RendererCurrent.user = "david"
    RendererCurrent.account = "acme"

    render plain: rendering.call
  end
end

class RendererCurrentAttributesTest < ActionController::TestCase
  include ActiveSupport::CurrentAttributes::TestHelper
  include ActiveSupport::ExecutionContext::TestHelper

  tests RendererCurrentAttributesController

  setup do
    @logger = ActiveSupport::LogSubscriber::TestHelper::MockLogger.new
  end

  test "false reads the request's values without checking" do
    assert_equal "<h1>Message</h1>\n<p>david, david at acme</p>\n", render_in_action(input: false, partial: "messages/current_user")
    assert_empty @logger.logged(:warn)
  end

  test ":log reads the request's values and warns once per attribute and render" do
    content = render_in_action(partial: "messages/current_user") do |render|
      render.call + render.call
    end

    assert_equal "<h1>Message</h1>\n<p>david, david at acme</p>\n" * 2, content

    warnings = @logger.logged(:warn)
    assert_equal 4, warnings.size
    assert_equal 2, warnings.count { |warning| warning.start_with?("`RendererCurrent.user` was read by a render of `messages/current_user` through ActionController::Renderer, and no `RendererCurrent.set` block opened during the action provides it.") }
    assert_equal 2, warnings.count { |warning| warning.start_with?("`RendererCurrent.account` was read") }
    assert_match "The render is not part of the action `RendererCurrentAttributesController#index`, during which the attribute was set", warnings.first
    assert_match "Pass the values it needs as locals, or provide it with `RendererCurrent.set(user: ...) { ... }`. " \
      "For the response to the current request, use `render_to_string`.", warnings.first
  end

  test ":notify reads the request's values and publishes an event per input, naming the processing controller" do
    content = nil
    events = capture_notifications("unprovided_renderer_input.action_controller") do
      content = render_in_action(input: :notify, partial: "messages/current_user") do |render|
        render.call + ApplicationController.render(inline: "<%= session[:user_id] %>")
      end
    end

    assert_equal "<h1>Message</h1>\n<p>david, david at acme</p>\n", content
    assert_equal [[:current_attributes, "RendererCurrent.user"], [:current_attributes, "RendererCurrent.account"], [:session, "user_id"]],
      events.map { |event| event.payload.values_at(:input, :key) }
    assert events.all? { |event| RendererCurrentAttributesController === event.payload[:controller] }

    payload = events.first.payload
    assert_match "`RendererCurrent.user` was read by a render", payload[:message]
    assert payload[:stack_trace].any? { |line| line.include?("messages/_current_user.html.erb") }
    assert_empty @logger.logged(:warn)
  end

  test ":raise raises naming the attribute, the render, the action and the template line" do
    error = assert_raises(ActionView::Template::Error) do
      render_in_action(input: :raise, partial: "messages/current_user")
    end

    assert_instance_of ActionController::Renderer::UnprovidedInputError, error.cause
    assert_kind_of ActionController::ActionControllerError, error.cause
    assert_match "`RendererCurrent.user` was read by a render of `messages/current_user` through ActionController::Renderer, " \
      "and no `RendererCurrent.set` block opened during the action provides it. " \
      "The render is not part of the action `RendererCurrentAttributesController#index`, during which the attribute was set", error.message
    assert_match "messages/_current_user.html.erb", error.file_name
    assert_equal "2", error.line_number
  end

  test ":raise raises again for an attribute whose first read was rescued" do
    error = assert_raises(ActionView::Template::Error) do
      render_in_action(input: :raise, inline: "<%= RendererCurrent.user rescue 'rescued' %>\n<%= RendererCurrent.user %>")
    end

    assert_instance_of ActionController::Renderer::UnprovidedInputError, error.cause
    assert_equal "2", error.line_number
  end

  test ":raise lets a render read the attributes a set block provides" do
    content = render_in_action(input: :raise, inline: "<%= RendererCurrent.user %>") do |render|
      RendererCurrent.set(user: "jane") { render.call }
    end
    assert_equal "jane", content

    error = assert_raises(ActionView::Template::Error) do
      render_in_action(input: :raise, partial: "messages/current_user") do |render|
        RendererCurrent.set(user: "jane") { render.call }
      end
    end
    assert_match "`RendererCurrent.account` was read", error.message
  end

  test ":raise lets a render read attributes at their default and classes the request did not use" do
    RendererUntouchedCurrent.instance
    content = render_in_action(input: :raise, inline: "<%= RendererCurrent.tags.inspect %> <%= RendererUntouchedCurrent.user.inspect %>")

    assert_equal "[] nil", content
  end

  test ":raise lets a render read what it wrote" do
    content = render_in_action(input: :raise, inline: "<% RendererCurrent.user = 'renderer' %><%= RendererCurrent.user %>")

    assert_equal "renderer", content
  end

  test ":raise reports a read of the request's value once the render's own write is set back" do
    error = assert_raises(ActionView::Template::Error) do
      render_in_action(
        input: :raise, restores: true,
        inline: "<%= ApplicationController.render(inline: inner) %>\n<%= RendererCurrent.user %>",
        locals: { inner: "<% RendererCurrent.user = 'inner' %>" }
      )
    end

    assert_match "`RendererCurrent.user` was read", error.message
    assert_equal "2", error.line_number
  end

  test "renderer_restores_current_attributes is false by default" do
    assert_equal false, ActionController::Base.renderer_restores_current_attributes
  end

  test "the attributes a render writes stay set for the request when renderer_restores_current_attributes is false" do
    content = render_in_action(inline: "<% RendererCurrent.user = 'renderer' %><% RendererCurrent.tags << 'renderer' %>") do |render|
      render.call
      "#{RendererCurrent.user} #{RendererCurrent.tags.inspect}"
    end

    assert_equal 'renderer ["renderer"]', content
  end

  test "renderer_restores_current_attributes sets back the attributes a render writes, for the request" do
    [false, :log, :raise].each do |action|
      content = render_in_action(input: action, restores: true, inline: "<% RendererCurrent.user = 'renderer' %><%= RendererCurrent.user %>") do |render|
        "#{render.call} #{RendererCurrent.user}"
      end

      assert_equal "renderer david", content
    end
  end

  test "renderer_restores_current_attributes sets back the attributes a render writes when it raises" do
    content = render_in_action(restores: true, inline: "<% RendererCurrent.user = 'renderer' %><% raise 'boom' %>") do |render|
      render.call
    rescue ActionView::Template::Error
      RendererCurrent.user
    end

    assert_equal "david", content
  end

  test "checking a render and setting back its writes run no reset callbacks" do
    resets_count = RendererCurrent.resets_count

    render_in_action(restores: true, inline: "<% RendererCurrent.user = 'renderer' %><%= RendererCurrent.account %>")

    assert_equal resets_count, RendererCurrent.resets_count
    assert_equal 1, @logger.logged(:warn).size
  end

  test "renderer_restores_current_attributes lets each render read what it is given, and not what an earlier render wrote" do
    renderer = ApplicationController.renderer
    template = "<%= RendererCurrent.user ||= session[:user_id] %>"
    render_for_recipients = -> { [{ user_id: "david" }, {}].map { |session| renderer.new("rack.session" => session).render(inline: template) } }

    ActionController::Base.with(action_on_unprovided_renderer_input: :raise, renderer_restores_current_attributes: false) do
      assert_equal ["david", "david"], render_for_recipients.call
      assert_equal "david", RendererCurrent.user
    end

    RendererCurrent.reset
    ActionController::Base.with(action_on_unprovided_renderer_input: :raise, renderer_restores_current_attributes: true) do
      assert_equal ["david", ""], render_for_recipients.call
      assert_nil RendererCurrent.user
    end
  end

  test "renderer_restores_current_attributes sets back what each render inside a Current.set block derives" do
    template = "<%= RendererCurrent.account ||= RendererCurrent.user.upcase %>"
    render_for_recipients = -> { ["david", "jane"].map { |user| RendererCurrent.set(user: user) { ApplicationController.render(inline: template) } } }

    ActionController::Base.with(action_on_unprovided_renderer_input: :raise, renderer_restores_current_attributes: false) do
      assert_equal ["DAVID", "DAVID"], render_for_recipients.call
      assert_equal "DAVID", RendererCurrent.account
    end

    RendererCurrent.reset
    ActionController::Base.with(action_on_unprovided_renderer_input: :raise, renderer_restores_current_attributes: true) do
      assert_equal ["DAVID", "JANE"], render_for_recipients.call
      assert_nil RendererCurrent.account
    end
  end

  test ":raise lets a render read what a set block in the render provides" do
    content = render_in_action(input: :raise, inline: "<%= RendererCurrent.set(user: 'jane') { RendererCurrent.user } %>") do |render|
      "#{render.call} #{RendererCurrent.user}"
    end

    assert_equal "jane david", content
  end

  test ":raise reports reading all the attributes" do
    error = assert_raises(ActionView::Template::Error) do
      render_in_action(input: :raise, inline: "<%= RendererCurrent.attributes.inspect %>")
    end

    assert_match "`RendererCurrent.user` was read", error.message
  end

  test "renders outside of an action are not checked for current attributes" do
    RendererCurrent.user = "david"

    ActionController::Base.with(action_on_unprovided_renderer_input: :raise) do
      assert_equal "david", ApplicationController.render(inline: "<%= RendererCurrent.user %>")
    end
  end

  private
    def render_in_action(input: :log, restores: false, **options)
      render = -> { ApplicationController.render(**options) }
      rendering = block_given? ? -> { yield render } : render

      ActionController::Base.with(action_on_unprovided_renderer_input: input, renderer_restores_current_attributes: restores) do
        ApplicationController.with(logger: @logger) do
          RendererCurrentAttributesController.with(rendering: rendering) { get :index }
        end
      end
      @response.body
    end
end

class RendererSetBlocksController < ActionController::Base
  class_attribute :renders, default: []

  INSIDE_AROUND = [:around, :around_with_set_blocks, :before_inside_around, :before_set_block_inside_around,
    :halted_inside_around, :halted_in_set_block_inside_around, :after_inside_around].freeze

  around_action :set_user, only: INSIDE_AROUND
  around_action :render_around_yield, only: :around_yield
  around_action :render_without_yield, only: :around_without_yield
  before_action :assign_user, only: :callbacks
  before_action :render_user_in_set_block, only: [:callbacks, :before_set_block_inside_around]
  before_action :render_user, only: [:before, :before_inside_around, :halted_inside_around]
  before_action :redirect, only: :halted_inside_around
  before_action :render_user_in_set_block_and_redirect, only: :halted_in_set_block_inside_around
  after_action :render_user_in_set_block, only: :callbacks
  after_action :render_user, only: :after_inside_around

  def around
    render_user
    head :ok
  end

  def around_with_set_blocks
    RendererCurrent.set(user: "jane") { render_user }
    RendererCurrent.set(account: "acme") do
      RendererCurrent.set(user: "jane") { render_user }
      render_user
    end
    head :ok
  end

  def callbacks
    render_user
    head :ok
  end

  def before
    render_user
    head :ok
  end

  def before_inside_around = head(:ok)
  def before_set_block_inside_around = head(:ok)
  def after_inside_around = head(:ok)
  def around_yield = head(:ok)

  # Never called: a callback halts first, or does not yield.
  def halted_inside_around = head(:ok)
  def halted_in_set_block_inside_around = head(:ok)
  def around_without_yield = head(:ok)

  private
    def set_user(&)
      RendererCurrent.set(user: "david", &)
    end

    def render_around_yield
      RendererCurrent.set(user: "david") do
        render_user
        yield
        render_user
      end
    end

    def render_without_yield
      RendererCurrent.set(user: "david") do
        render_user
        head :ok
      end
    end

    def assign_user
      RendererCurrent.user = "david"
    end

    def redirect
      redirect_to "/"
    end

    def render_user_in_set_block
      RendererCurrent.set(user: "jane") { render_user }
    end

    def render_user_in_set_block_and_redirect
      RendererCurrent.set(user: "jane") do
        render_user
        redirect_to "/"
      end
    end

    def render_user
      renders << ApplicationController.render(inline: "<%= RendererCurrent.user %>")
    rescue ActionView::Template::Error => error
      raise unless ActionController::Renderer::UnprovidedInputError === error.cause
      renders << "unprovided"
    end
end

class RendererLiveSetBlocksController < ActionController::Base
  include ActionController::Live

  around_action { |_, action| RendererCurrent.set(user: "david") { action.call } }

  def index
    response.stream.write ApplicationController.render(inline: "<%= RendererCurrent.user %>")
  rescue ActionView::Template::Error => error
    response.stream.write error.cause.class.name
  ensure
    response.stream.close
  end
end

class RendererSetBlocksTest < ActionController::TestCase
  include ActiveSupport::CurrentAttributes::TestHelper
  include ActiveSupport::ExecutionContext::TestHelper

  tests RendererSetBlocksController

  test "a set block an around_action opens around the action does not provide its attributes" do
    assert_equal ["unprovided"], renders_of(:around)
  end

  test "set blocks opened in the action provide their attributes inside an around_action's block" do
    assert_equal ["jane", "jane", "unprovided"], renders_of(:around_with_set_blocks)
  end

  test "set blocks opened in before_action and after_action callbacks provide their attributes" do
    assert_equal ["jane", "unprovided", "jane"], renders_of(:callbacks)
  end

  test "an around_action's block does not provide its attributes to an after_action it encloses" do
    assert_equal ["unprovided"], renders_of(:after_inside_around)
  end

  test "an around_action's block provides its attributes before the action method is called" do
    assert_equal ["david"], renders_of(:before_inside_around)
    assert_equal ["david", "unprovided"], renders_of(:around_yield)
    assert_equal ["david"], renders_of(:halted_inside_around)
    assert_equal ["david"], renders_of(:around_without_yield)
  end

  test "a set block a before_action opens provides its attributes inside an around_action's block" do
    assert_equal ["jane"], renders_of(:before_set_block_inside_around)
  end

  test "a set block a halting before_action opens provides its attributes" do
    assert_equal ["jane"], renders_of(:halted_in_set_block_inside_around)
    assert_response :redirect
  end

  test "a set block open as the controller starts processing does not provide its attributes" do
    RendererCurrent.set(user: "david") do
      assert_equal ["unprovided", "unprovided"], renders_of(:before)
    end
  end

  test "an around_action's block does not provide its attributes to a live action" do
    @controller = RendererLiveSetBlocksController.new
    ActionController::Base.with(action_on_unprovided_renderer_input: :raise) { get :index }

    assert_equal "ActionController::Renderer::UnprovidedInputError", response.body
  end

  private
    def renders_of(action)
      RendererSetBlocksController.renders = []
      ActionController::Base.with(action_on_unprovided_renderer_input: :raise) { get action }
      RendererSetBlocksController.renders
    end
end
