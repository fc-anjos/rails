# frozen_string_literal: true

# :markup: markdown

module ActionController
  class Renderer
    # The cookies of a render that was not given any. It reports its reads before
    # answering them as an empty cookie jar does. Signed and encrypted cookies are
    # read through it. A cookie the render sets is its own, and reading it back is
    # not reported.
    class WithheldCookieJar < ActionDispatch::Cookies::CookieJar # :nodoc:
      # Without a key generator in the env, opening a signed or encrypted jar
      # raises NoMethodError before any cookie is named, so the read is reported
      # as the jar opens, and then raises as it does without the setting.
      module ChainedJars
        def permanent
          @permanent ||= Permanent.new(self)
        end

        def signed
          unprovided_jar_read "signed"
          super
        end

        def encrypted
          unprovided_jar_read "encrypted"
          super
        end

        private
          def unprovided_jar_read(jar)
            unless request.key_generator
              request.unprovided_inputs.read(:cookies, nil, "#{jar_path}.#{jar}")
            end
          end
      end

      # The jar `cookies.permanent.signed` and `cookies.permanent.encrypted` open
      # from.
      class Permanent < ActionDispatch::Cookies::PermanentCookieJar
        include ChainedJars

        private
          def jar_path
            "cookies.permanent"
          end
      end

      include ChainedJars

      def [](name)
        unprovided_read name
        super
      end

      def fetch(name, *)
        unprovided_read name
        super
      end

      def key?(name)
        unprovided_read name
        super
      end
      alias :has_key? :key?

      # `to_hash` and the other Enumerable methods read through `each`.
      def each(&)
        unprovided_read
        super
      end

      private
        def jar_path
          "cookies"
        end

        def unprovided_read(name = nil)
          unless name && @cookies.key?(name.to_s)
            @request.unprovided_inputs.read(:cookies, name)
          end
        end
    end
  end
end
