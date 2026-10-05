# frozen_string_literal: true

# :markup: markdown

module ActionController
  class Renderer
    # The request of a render that reports reads of inputs it was not given. The
    # session, cookie jar and flash that its env does not carry are created on
    # first use, as a request creates them, but withheld: they report their reads
    # to the render's UnprovidedInputs.
    class WithholdingRequest < ActionDispatch::Request # :nodoc:
      attr_reader :unprovided_inputs

      def initialize(env, unprovided_inputs)
        super(env)
        @unprovided_inputs = unprovided_inputs
      end

      def cookie_jar
        if have_cookie_jar? || has_header?("HTTP_COOKIE")
          super
        else
          self.cookie_jar = WithheldCookieJar.new(self)
        end
      end

      # The flash is read from the session, so a render given a session reads the
      # flash it holds.
      def flash_hash
        super || (self.flash = WithheldFlash.new(unprovided_inputs) if WithheldSession === session)
      end

      private
        def default_session
          WithheldSession.disabled(self)
        end
    end
  end
end
