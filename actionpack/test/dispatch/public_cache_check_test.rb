# frozen_string_literal: true

require "abstract_unit"

class PublicCacheCheckTest < ActionDispatch::IntegrationTest
  include CookieSessionAppTestHelpers

  class TestController < ActionController::Base
    def sign_in
      session[:user_id] = 1
      head :ok
    end

    def public_reading_session
      expires_in 1.hour, public: true
      render plain: "user: #{session[:user_id]}"
    end

    def public_setting_cookie
      expires_in 1.hour, public: true
      cookies[:theme] = "dark"
      head :ok
    end

    def public_rendering_a_form
      expires_in 1.hour, public: true
      render inline: "<%= form_tag('/') {} %>"
    end

    def public_without_input
      expires_in 1.hour, public: true
      render plain: "hello"
    end

    def private_reading_session
      expires_in 1.hour
      render plain: "user: #{session[:user_id]}"
    end
  end

  class CheckConfigMiddleware
    def initialize(app, action)
      @app = app
      @action = action
    end

    def call(env)
      env["action_dispatch.action_on_unsafe_public_cache"] = @action
      env["action_dispatch.logger"] = PublicCacheCheckTest.logger
      @app.call(env)
    end
  end

  cattr_accessor :logger

  setup do
    @subscriber = ActionDispatch::PublicCacheCheck.subscribe
    @log = StringIO.new
    self.class.logger = ActiveSupport::Logger.new(@log)
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@subscriber)
  end

  test "logs a public response that read the session" do
    with_check(:log) do
      get "/sign_in"
      get "/public_reading_session"

      assert_response :success
      assert_equal "user: 1", response.body
      assert_match 'GET /public_reading_session responded with `Cache-Control: max-age=3600, public` but read session["user_id"]. A shared cache', @log.string
    end
  end

  test "raises for a public response that read the session" do
    with_check(:raise) do
      get "/sign_in"

      error = assert_raises(ActionDispatch::UnsafePublicCacheError) { get "/public_reading_session" }
      assert_match 'read session["user_id"]', error.message
    end
  end

  test "raises for a public response that sets a cookie" do
    with_check(:raise) do
      error = assert_raises(ActionDispatch::UnsafePublicCacheError) { get "/public_setting_cookie" }
      assert_match "but set the cookie theme.", error.message
    end
  end

  test "raises for a public response that renders the authenticity token" do
    with_check(:raise) do
      error = assert_raises(ActionDispatch::UnsafePublicCacheError) { get "/public_rendering_a_form" }
      assert_match "read csrf_token", error.message
    end
  end

  test "passes a public response that read no input and sets no cookie" do
    with_check(:raise) do
      get "/sign_in"
      get "/public_without_input"

      assert_response :success
      assert_equal "public", response.headers["Cache-Control"].split(", ").last
    end
  end

  test "passes a private response that read the session" do
    with_check(:raise) do
      get "/sign_in"
      get "/private_reading_session"

      assert_response :success
      assert_equal "user: 1", response.body
    end
  end

  test "checks nothing when disabled" do
    with_check(false) do
      get "/sign_in"
      get "/public_reading_session"

      assert_response :success
      assert_empty @log.string
    end
  end

  test "closes the response body before raising" do
    body = Rack::BodyProxy.new(["hello"]) { }
    app = ActionDispatch::Cookies.new(lambda do |env|
      ActionDispatch::Request.new(env).cookie_jar[:theme] = "dark"
      [200, { Rack::CACHE_CONTROL => "public, max-age=60" }, body]
    end)
    env = Rack::MockRequest.env_for("/", "action_dispatch.action_on_unsafe_public_cache" => :raise)

    assert_raises(ActionDispatch::UnsafePublicCacheError) { app.call(env) }
    assert_predicate body, :closed?
  end

  private
    def with_check(action, &)
      with_cookie_session_app(TestController, CheckConfigMiddleware, action, &)
    end
end
