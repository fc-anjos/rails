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
  # It sees only what it is given:
  #
  # * a session, cookies and a flash only when they are passed in its env (the
  #   flash is read from the session), so a render that is not given them reads
  #   `nil` from them, directly or through a helper method such as
  #   `current_user`. Its request has no key generator, so `cookies.signed` and
  #   `cookies.encrypted` raise NoMethodError;
  # * ActiveSupport::CurrentAttributes from the calling thread. When the render
  #   is made while a controller is processing an action, or an Action Cable
  #   channel a command, a `Current` attribute set for the request, like
  #   `Current.user`, holds that request's value, and the render is given it
  #   only while a `Current.set` block naming it is open.
  #
  # Pass the values a render needs as locals, or wrap the render in a
  # `Current.set` block giving the attributes it reads the values it is meant to
  # see:
  #
  #     ApplicationController.render partial: "messages/message", locals: { message: message }
  #
  #     Current.set(user: nil) do
  #       ApplicationController.render partial: "messages/message", locals: { message: message }
  #     end
  #
  # `config.action_controller.action_on_unprovided_renderer_input` controls what
  # happens when a render reads an input it was not given:
  #
  # * `:log` - Logs a warning, once per render and input, and reads what it reads
  #   without the setting
  # * `:notify` - Sends an `unprovided_renderer_input.action_controller` Active
  #   Support notification and structured event, including a stack trace, once
  #   per render and input, and reads what it reads without the setting
  # * `:raise` - Raises an UnprovidedInputError naming what was read
  # * `false` - Reads `nil` from a session, cookies or flash it was not given, and
  #   the request's `Current` attributes
  #
  # A signed or encrypted cookie read by a render that was not given cookies is
  # reported as it opens `cookies.signed` or `cookies.encrypted`, before the
  # missing key generator raises. With `:log` and `:notify` the read then raises
  # NoMethodError, as it does with `false`.
  #
  # Writes are not reported: session writes raise as they do in a request without
  # a session store, and cookies and flash messages the render sets are its own.
  # Forms, `button_to` and `csrf_meta_tags` render without an authenticity token,
  # as a token rendered outside a request cannot be verified.
  #
  # An attribute is provided while a `Current.set` block naming it is open, if the
  # block was opened during the action: in the action method, in a
  # `before_action` or `after_action` callback, or in code they call, such as a
  # model callback. A block that is still open when the action method is called,
  # opened by a middleware or by an `around_action`, holds the request's state,
  # as an attribute assigned in a `before_action` does, and provides nothing.
  # Before the action method is called, such a block is not yet told apart from
  # one opened around a render, so a render made in a `before_action` that runs
  # inside an `around_action`'s block, or in the `around_action` before it
  # yields, is given its attributes.
  #
  # Action Cable channel commands are checked the same way, with the channel's
  # action method, `subscribed` or `unsubscribed` in place of the action method,
  # and `around_command` in place of `around_action`. Renders made outside of a
  # controller action or a channel command, for example in a job, in a
  # middleware before the controller, or in a mounted Rack application, are not
  # checked for `Current` attributes.
  #
  # ## `Current` attributes a render writes
  #
  # A render can write `Current` attributes, for example through a helper method
  # that memoizes a value with `Current.account ||= Current.user.account`. With
  # `config.action_controller.renderer_restores_current_attributes` enabled, they
  # are set back when the render ends, also when it raises: each attribute the
  # render wrote gets the value it held when the render started, through the
  # attribute's writer, as when a `Current.set` block ends, so a writer that also
  # sets `Time.zone` sets it back too. A `Current` class first used in the render
  # is set back to its defaults through its writers, and its instance is
  # discarded. No reset callbacks run. Each render then reads what its caller
  # provides, and not what an earlier render wrote:
  #
  #     recipients.map do |user|
  #       Current.set(user: user) do
  #         ApplicationController.render partial: "messages/message", locals: { message: message }
  #       end
  #     end
  #
  # When it is disabled, the attributes a render writes stay set after it, for
  # its caller and for every later render on the same thread. In the example, a
  # partial calling such a helper method renders every recipient after the first
  # with the first one's account.
  #
  class Renderer
    # Raised when a render through the renderer reads an input it was not given.
    class UnprovidedInputError < ActionControllerError
    end

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
      if action = controller.action_on_unprovided_renderer_input
        unprovided_inputs = UnprovidedInputs.new(action, controller, args)
        request = WithholdingRequest.new(env_for_request, unprovided_inputs)
      else
        request = ActionDispatch::Request.new(env_for_request)
      end
      request.routes = controller._routes

      instance = controller.new
      instance.set_request! request
      instance.set_response! controller.make_response!(request)

      if controller.renderer_restores_current_attributes
        ActiveSupport::CurrentAttributes.restoring_writes { render_observing_current_attributes(instance, unprovided_inputs, *args, &block) }
      else
        render_observing_current_attributes(instance, unprovided_inputs, *args, &block)
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

      def render_observing_current_attributes(instance, unprovided_inputs, *args, &block)
        if unprovided_inputs&.processing
          on_read = ->(current, name) { unprovided_inputs.read_current_attribute(current, name) }
          ActiveSupport::CurrentAttributes.observing_reads(on_read) { instance.render_to_string(*args, &block) }
        else
          instance.render_to_string(*args, &block)
        end
      end

      def env_for_request
        if @env.key?("HTTP_HOST") || controller._routes.nil?
          @env.dup
        else
          controller._routes.default_env.merge(@env)
        end
      end
  end
end
