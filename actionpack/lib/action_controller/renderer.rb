# frozen_string_literal: true

# :markup: markdown

module ActionController
  # # Action Controller Renderer
  #
  # ActionController::Renderer allows you to render arbitrary templates without
  # being inside a controller action.
  #
  # You can get a renderer instance by calling `renderer` on a controller class:
  #
  #     ApplicationController.renderer
  #     PostsController.renderer
  #
  # and render a template by calling the #render method:
  #
  #     ApplicationController.renderer.render template: "posts/show", assigns: { post: Post.first }
  #     PostsController.renderer.render :show, assigns: { post: Post.first }
  #
  # As a shortcut, you can also call `render` directly on the controller class
  # itself:
  #
  #     ApplicationController.render template: "posts/show", assigns: { post: Post.first }
  #     PostsController.render :show, assigns: { post: Post.first }
  #
  # ## Rendering outside a request
  #
  # A render through the renderer is not the response to any request, and its
  # output may be sent to other users, for example in a Turbo Stream broadcast.
  # Give it what it needs as locals:
  #
  #     ApplicationController.render partial: "messages/message",
  #       locals: { message: message, viewer: nil }
  #
  # A session, cookies and a flash are given only when they are passed in its
  # env, so a render that is not given them reads `nil` from them, directly or
  # through a helper method such as `current_user`. Its request has no key
  # generator, so `cookies.signed` and `cookies.encrypted` raise NoMethodError.
  #
  # With `config.action_controller.renderer_isolates_current_attributes`
  # enabled, the render runs with its own ActiveSupport::CurrentAttributes and
  # execution context, as a job performed by a queue does, so a render made
  # during an action, or inside a `Current.set` block, does not see the
  # caller's `Current.user`. Whatever the render writes to `Current` is
  # discarded when it ends, and the caller's attributes are put back through
  # their writers, as when a `Current.set` block ends. `Time.zone` and
  # `I18n.locale` are the caller's, as Active Job carries them into a job. The
  # URL options Active Storage builds blob URLs from are carried in.
  #
  # `config.action_controller.action_on_unprovided_renderer_input` controls what
  # happens when a render reads an input it was not given: a session, cookies or
  # flash missing from its env and, with isolation enabled, a `Current` attribute
  # that its caller had set:
  #
  # * `:log` - Logs a warning, once per render and input, and reads what it reads
  #   without the setting
  # * `:notify` - Sends an `unprovided_renderer_input.action_controller` Active
  #   Support notification, including a stack trace, once per render and input,
  #   and reads what it reads without the setting
  # * `:raise` - Raises an UnprovidedInputError naming what was read
  # * `false` - Reports nothing
  #
  # A signed or encrypted cookie read by a render that was not given cookies is
  # reported as it opens `cookies.signed` or `cookies.encrypted`, before the
  # missing key generator raises. With `:log` and `:notify` the read then raises
  # NoMethodError, as it does with `false`.
  class Renderer
    # Raised when a render through the renderer reads an input it was not given.
    class UnprovidedInputError < ActionControllerError
    end

    autoload :Inputs,              "action_controller/renderer/inputs"
    autoload :UnprovidedInputs,    "action_controller/renderer/unprovided_inputs"
    autoload :WithholdingRequest,  "action_controller/renderer/withholding_request"
    autoload :WithheldSession,     "action_controller/renderer/withheld_session"
    autoload :WithheldCookieJar,   "action_controller/renderer/withheld_cookie_jar"
    autoload :WithheldFlash,       "action_controller/renderer/withheld_flash"

    attr_reader :controller

    DEFAULTS = {
      method: "get",
      input: ""
    }.freeze

    def self.normalize_env(env) # :nodoc:
      new_env = {}

      env.each_pair do |key, value|
        case key
        when :https
          value = value ? "on" : "off"
        when :method
          value = -value.upcase
        end

        key = RACK_KEY_TRANSLATION[key] || key.to_s

        new_env[key] = value
      end

      if new_env["HTTP_HOST"]
        new_env["HTTPS"] ||= "off"
        new_env["SCRIPT_NAME"] ||= ""
      end

      if new_env["HTTPS"]
        new_env["rack.url_scheme"] = new_env["HTTPS"] == "on" ? "https" : "http"
      end

      new_env
    end

    # Creates a new renderer using the given controller class. See ::new.
    def self.for(controller, env = nil, defaults = DEFAULTS)
      new(controller, env, defaults)
    end

    # Creates a new renderer using the same controller, but with a new Rack env.
    #
    #     ApplicationController.renderer.new(method: "post")
    #
    def new(env = nil)
      self.class.new controller, env, @defaults
    end

    # Creates a new renderer using the same controller, but with the given defaults
    # merged on top of the previous defaults.
    def with_defaults(defaults)
      self.class.new controller, @env, @defaults.merge(defaults)
    end

    # Initializes a new Renderer.
    #
    # #### Parameters
    #
    # *   `controller` - The controller class to instantiate for rendering.
    # *   `env` - The Rack env to use for mocking a request when rendering. Entries
    #     can be typical Rack env keys and values, or they can be any of the
    #     following, which will be converted appropriately:
    #     *   `:http_host` - The HTTP host for the incoming request. Converts to
    #         Rack's `HTTP_HOST`.
    #     *   `:https` - Boolean indicating whether the incoming request uses HTTPS.
    #         Converts to Rack's `HTTPS`.
    #     *   `:method` - The HTTP method for the incoming request,
    #         case-insensitive. Converts to Rack's `REQUEST_METHOD`.
    #     *   `:script_name` - The portion of the incoming request's URL path that
    #         corresponds to the application. Converts to Rack's `SCRIPT_NAME`.
    #     *   `:input` - The input stream. Converts to Rack's `rack.input`.
    # *   `defaults` - Default values for the Rack env. Entries are specified in the
    #     same format as `env`. `env` will be merged on top of these values.
    #     `defaults` will be retained when calling #new on a renderer instance.
    #
    #
    # If no `http_host` is specified, the env HTTP host will be derived from the
    # routes' `default_url_options`. In this case, the `https` boolean and the
    # `script_name` will also be derived from `default_url_options` if they were not
    # specified. Additionally, the `https` boolean will fall back to
    # `Rails.application.config.force_ssl` if `default_url_options` does not specify
    # a `protocol`.
    def initialize(controller, env, defaults)
      @controller = controller
      @defaults = defaults
      if env.blank? && @defaults == DEFAULTS
        @env = DEFAULT_ENV
      else
        @env = normalize_env(@defaults)
        @env.merge!(normalize_env(env)) unless env.blank?
      end
    end

    def defaults
      @defaults = @defaults.dup if @defaults.frozen?
      @defaults
    end

    # Renders a template to a string, just like
    # ActionController::Rendering#render_to_string.
    def render(*args, &block)
      inputs = Inputs.new(controller, env_for_request, args)
      request = inputs.request
      request.routes = controller._routes

      instance = controller.new
      instance.set_request! request
      instance.set_response! controller.make_response!(request)

      inputs.rendering do
        instance.render_to_string(*args, &block)
      end
    end
    alias_method :render_to_string, :render # :nodoc:

    private
      RACK_KEY_TRANSLATION = {
        http_host:   "HTTP_HOST",
        https:       "HTTPS",
        method:      "REQUEST_METHOD",
        script_name: "SCRIPT_NAME",
        input:       "rack.input"
      }.freeze

      DEFAULT_ENV = normalize_env(DEFAULTS).freeze # :nodoc:

      delegate :normalize_env, to: :class

      def env_for_request
        if @env.key?("HTTP_HOST") || controller._routes.nil?
          @env.dup
        else
          controller._routes.default_env.merge(@env)
        end
      end
  end
end
