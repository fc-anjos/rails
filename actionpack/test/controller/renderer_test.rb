# frozen_string_literal: true

require "abstract_unit"
require "test_renderable"
require "active_support/key_generator"
require "active_support/messages/rotation_configuration"
require "active_support/current_attributes/test_helper"
require "active_support/execution_context/test_helper"
require "active_support/log_subscriber/test_helper"

# The renderer generates URLs through the route set +ActionController::Base+
# was set up with.
append_routes(SharedTestRoutes) do
  get "/posts", to: "posts#index"
end

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
        "for example in a Turbo Stream broadcast. Pass the values it needs as locals.", @logger.logged(:warn).first

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
        assert_match "Pass the values it needs as locals.", error.message
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


class RendererIsolationCurrent < ActiveSupport::CurrentAttributes
  attribute :user, :role, :tenant, :zone
  attribute :host

  resets { Time.zone = nil }

  def zone=(zone)
    super
    Time.zone = zone
  end
end

class RendererIsolationController < ActionController::Base
  cattr_accessor :renders, default: []

  before_action { RendererIsolationCurrent.user = "david" }

  def broadcast
    renders << self.class.render(inline: "<%= RendererIsolationCurrent.user.inspect %>")
    render plain: RendererIsolationCurrent.user
  end

  def broadcast_with_locals
    renders << self.class.render(inline: "<%= viewer.inspect %>", locals: { viewer: nil })
    render plain: RendererIsolationCurrent.user
  end

  def broadcast_per_recipient
    %w[jeremy jose].each do |recipient|
      renders << self.class.render(
        inline: "<%= RendererIsolationCurrent.role ||= \"role of \#{recipient}\" %>",
        locals: { recipient: recipient }
      )
    end
    render plain: "#{RendererIsolationCurrent.user} #{RendererIsolationCurrent.role.inspect}"
  end

  def broadcast_in_set_block
    RendererIsolationCurrent.set(tenant: "acme") do
      renders << self.class.render(inline: "<%= RendererIsolationCurrent.tenant.inspect %>")
    end
    render plain: RendererIsolationCurrent.user
  end

  def broadcast_given_tenant_as_local
    RendererIsolationCurrent.set(tenant: "acme") do
      renders << self.class.render(inline: "<%= tenant.inspect %>", locals: { tenant: RendererIsolationCurrent.tenant })
    end
    render plain: RendererIsolationCurrent.user
  end

  def broadcast_setting_its_own
    renders << self.class.render(
      inline: "<% RendererIsolationCurrent.user = viewer %><%= RendererIsolationCurrent.user.inspect %>",
      locals: { viewer: nil }
    )
    render plain: RendererIsolationCurrent.user
  end

  def broadcast_carried
    RendererIsolationCurrent.host = "example.com"
    renders << self.class.render(inline: "<%= RendererIsolationCurrent.host.inspect %>")
    render plain: RendererIsolationCurrent.user
  end

  def broadcast_writing_zone
    RendererIsolationCurrent.zone = "Copenhagen"
    I18n.with_locale(:de) do
      renders << self.class.render(inline: "<%= Time.zone&.name.inspect %> <%= I18n.locale %> <% RendererIsolationCurrent.zone = 'Tokyo' %><%= Time.zone.name %>")
    end
    render plain: Time.zone.name
  end

  def broadcast_raising
    RendererIsolationCurrent.role = "admin"
    begin
      self.class.render(inline: "<% RendererIsolationCurrent.role = 'guest' %><% raise 'boom' %>")
    rescue ActionView::Template::Error
      renders << "raised"
    end
    render plain: RendererIsolationCurrent.role
  end
end

class RendererIsolationTest < ActionController::TestCase
  tests RendererIsolationController

  setup do
    RendererIsolationController.renders = []
    @logger = ActiveSupport::LogSubscriber::TestHelper::MockLogger.new
    @original_logger, RendererIsolationController.logger = RendererIsolationController.logger, @logger
    @carried = ActiveSupport::CurrentAttributes::Isolation.carried
    ActiveSupport::CurrentAttributes::Isolation.carry(RendererIsolationCurrent, :host)
  end

  teardown do
    RendererIsolationController.logger = @original_logger
    ActiveSupport::CurrentAttributes::Isolation.instance_variable_set(:@carried, @carried)
    RendererIsolationCurrent.reset
    Time.zone = nil
  end

  test "renderer_isolates_execution_state is false by default" do
    assert_equal false, ActionController::Base.renderer_isolates_execution_state
  end

  test "without isolation, a render during an action reads the request's Current attributes, unreported" do
    render_in_action :broadcast, isolates: false, input: :raise

    assert_equal ["&quot;david&quot;"], renders
  end

  test "with isolation, a render during an action does not read the request's Current attributes" do
    render_in_action :broadcast, input: false

    assert_equal ["nil"], renders
    assert_equal "david", @response.body
  end

  test "with isolation, :log warns of a read of an attribute the caller had set, pointing to locals" do
    render_in_action :broadcast, input: :log

    assert_equal ["nil"], renders
    assert_equal 1, @logger.logged(:warn).size
    assert_equal "`RendererIsolationCurrent.user` was read by a render through ActionController::Renderer, " \
      "which renders with `Current` attributes of its own, so it read `nil` or the attribute's default. " \
      "Its caller had set `RendererIsolationCurrent.user`, including with a `RendererIsolationCurrent.set` block " \
      "around the render, but the render's output may be sent to other users, for example in a Turbo Stream " \
      "broadcast. Pass the values it needs as locals, for example `locals: { user: ... }`, and read them in place " \
      "of `RendererIsolationCurrent.user`.", @logger.logged(:warn).first
  end

  test "with isolation, :notify publishes a read of an attribute the caller had set" do
    events = capture_notifications("unprovided_renderer_input.action_controller") do
      render_in_action :broadcast, input: :notify
    end

    assert_equal [[:current_attributes, "RendererIsolationCurrent.user"]], events.map { |event| event.payload.values_at(:input, :key) }
  end

  test "with isolation, :raise raises on a read of an attribute the caller had set" do
    error = assert_raises(ActionView::Template::Error) { render_in_action :broadcast, input: :raise }

    assert_instance_of ActionController::Renderer::UnprovidedInputError, error.cause
    assert_match "`RendererIsolationCurrent.user` was read by a render", error.message
  end

  test "with isolation, a render given its values as locals is not reported" do
    render_in_action :broadcast_with_locals, input: :raise

    assert_equal ["nil"], renders
  end

  test "with isolation, a render that sets the attribute itself before reading it is not reported" do
    render_in_action :broadcast_setting_its_own, input: :raise

    assert_equal ["nil"], renders
    assert_equal "david", @response.body
  end

  test "with isolation, a memoized attribute is computed for each render, and its writes are discarded" do
    render_in_action :broadcast_per_recipient, input: :raise

    assert_equal ["role of jeremy", "role of jose"], renders
    assert_equal "david nil", @response.body
  end

  test "without isolation, a memoized attribute written by one render is read by the next and by the caller" do
    render_in_action :broadcast_per_recipient, isolates: false

    assert_equal ["role of jeremy", "role of jeremy"], renders
    assert_equal "david \"role of jeremy\"", @response.body
  end

  test "with isolation, an enclosing Current.set block does not give the render its attributes, and the read is reported" do
    render_in_action :broadcast_in_set_block, input: false
    assert_equal ["nil"], renders

    error = assert_raises(ActionView::Template::Error) { render_in_action :broadcast_in_set_block, input: :raise }
    assert_match "`RendererIsolationCurrent.tenant` was read by a render", error.message
    assert_match "`locals: { tenant: ... }`", error.message
  end

  test "with isolation, a value from an enclosing Current.set block reaches the render as a local" do
    render_in_action :broadcast_given_tenant_as_local, input: :raise

    assert_equal ["&quot;acme&quot;"], renders
  end

  test "without isolation, an enclosing Current.set block gives the render its attributes" do
    render_in_action :broadcast_in_set_block, isolates: false

    assert_equal ["&quot;acme&quot;"], renders
  end

  test "with isolation, the attributes declared with Isolation.carry are carried, and not reported" do
    render_in_action :broadcast_carried, input: :raise

    assert_equal ["&quot;example.com&quot;"], renders
  end

  test "with isolation and no job context, a render does not receive the caller's Time.zone, and its writer's side effects are undone" do
    render_in_action :broadcast_writing_zone, input: false

    assert_equal ["nil de Tokyo"], renders
    assert_equal "Copenhagen", @response.body
  end

  ZoneJobContext = Struct.new(:zone) do
    def self.capture = new(Time.zone)
    def perform(&block) = Time.use_zone(zone, &block)
  end

  test "with isolation, a render receives what the job context captures from its caller" do
    ActionController::Renderer.job_context, original = ZoneJobContext, ActionController::Renderer.job_context
    render_in_action :broadcast_writing_zone, input: false

    assert_equal ["&quot;Copenhagen&quot; de Tokyo"], renders
    assert_equal "Copenhagen", @response.body
  ensure
    ActionController::Renderer.job_context = original
  end

  test "with isolation, a render's writes are discarded when it raises" do
    render_in_action :broadcast_raising, input: false

    assert_equal ["raised"], renders
    assert_equal "admin", @response.body
  end

  test "with isolation, a render outside of an action is not reported" do
    with_renderer_settings(input: :raise, isolates: true) do
      assert_equal "nil", RendererIsolationController.render(inline: "<%= RendererIsolationCurrent.user.inspect %>")
    end
  end

  test "with isolation, the caller's Current instances are untouched by the render" do
    with_renderer_settings(input: false, isolates: true) do
      RendererIsolationCurrent.user = "david"
      instance = RendererIsolationCurrent.instance

      RendererIsolationController.render(inline: "<% RendererIsolationCurrent.user = 'jose' %>")

      assert_same instance, RendererIsolationCurrent.instance
      assert_equal "david", RendererIsolationCurrent.user
    ensure
      RendererIsolationCurrent.reset
    end
  end

  private
    def renders
      RendererIsolationController.renders
    end

    def render_in_action(action, input: :log, isolates: true)
      with_renderer_settings(input: input, isolates: isolates) { get action }
    end

    def with_renderer_settings(input:, isolates:)
      original = [ActionController::Base.action_on_unprovided_renderer_input, ActionController::Base.renderer_isolates_execution_state]
      ActionController::Base.action_on_unprovided_renderer_input = input
      ActionController::Base.renderer_isolates_execution_state = isolates
      yield
    ensure
      ActionController::Base.action_on_unprovided_renderer_input, ActionController::Base.renderer_isolates_execution_state = original
    end
end
