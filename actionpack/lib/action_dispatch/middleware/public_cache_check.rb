# frozen_string_literal: true

# :markup: markdown

module ActionDispatch
  # Raised when a response marked `Cache-Control: public` read request input or
  # sets a cookie, and `config.action_dispatch.action_on_unsafe_public_cache` is
  # `:raise`.
  class UnsafePublicCacheError < StandardError
  end

  # Checks responses that shared caches may store and serve to every user. Such a
  # response must not depend on who requested it, so it must not read the
  # session, cookies, flash, CSRF token or content security policy nonce, and must
  # not set cookies. The reads are the `read_input.action_dispatch` events
  # published while the request was processed.
  module PublicCacheCheck # :nodoc:
    INPUTS_READ = "action_dispatch.inputs_read"
    PUBLIC_DIRECTIVE = /(?:\A|,)\s*public\s*(?:,|\z)/i

    class << self
      # Records the inputs read by every request, for as long as the subscription
      # lasts.
      def subscribe
        ActiveSupport::Notifications.subscribe(Request::READ_INPUT_EVENT) do |_name, _start, _finish, _id, payload|
          # Shared caches key responses on the URL, which holds the params.
          unless payload[:input] == :params
            record_read(payload[:request], payload[:input], payload[:key])
          end
        end
      end

      def check(request, action, headers)
        cache_control = headers[Rack::CACHE_CONTROL]
        return unless cache_control && PUBLIC_DIRECTIVE.match?(cache_control)

        inputs = request.get_header(INPUTS_READ) || []
        cookies = cookie_names(headers[Rack::SET_COOKIE])
        return if inputs.empty? && cookies.empty?

        message = message(request, cache_control, inputs, cookies)

        case action
        when :raise
          raise UnsafePublicCacheError, message
        when :log
          request.logger&.warn(message)
        end
      end

      private
        def record_read(request, input, key)
          inputs = request.get_header(INPUTS_READ) || request.set_header(INPUTS_READ, [])
          read = key ? "#{input}[#{key.inspect}]" : input.to_s
          inputs << read unless inputs.include?(read)
        end

        def cookie_names(set_cookie)
          Array(set_cookie).flat_map { |header| header.split("\n") }.map { |cookie| cookie[/\A[^=;]*/].strip }.uniq
        end

        def message(request, cache_control, inputs, cookies)
          reasons = []
          reasons << "read #{inputs.join(", ")}" if inputs.any?
          reasons << "set the #{cookies.one? ? "cookie" : "cookies"} #{cookies.join(", ")}" if cookies.any?

          "#{request.request_method} #{request.path} responded with `Cache-Control: #{cache_control}` " \
            "but #{reasons.join(" and ")}. A shared cache, such as a CDN or proxy, may store this response " \
            "and serve it to other users. Make the response private, or build it without reading the session, " \
            "cookies, flash, CSRF token or content security policy nonce and without setting cookies."
        end
    end
  end
end
