# frozen_string_literal: true

# :markup: markdown

module ActionController
  class Renderer
    # The session of a render that was not given one. It is disabled, like the
    # session of a request made without a session store, and it reports its reads
    # before answering them as that session does.
    class WithheldSession < ActionDispatch::Http::Session # :nodoc:
      def [](key)
        unprovided_read key
        super
      end

      def dig(key, *)
        unprovided_read key
        super
      end

      def has_key?(key)
        unprovided_read key
        super
      end
      alias :key? :has_key?
      alias :include? :has_key?

      def fetch(key, *)
        unprovided_read key
        super
      end

      def keys
        unprovided_read
        super
      end

      def values
        unprovided_read
        super
      end

      # `each` reads through `to_hash`.
      def to_hash
        unprovided_read
        super
      end
      alias :to_h :to_hash

      def empty?
        unprovided_read
        super
      end

      def id
        unprovided_read "session_id", "session.id"
        super
      end

      def id_was
        unprovided_read "session_id", "session.id"
        super
      end

      private
        def unprovided_read(key = nil, read = nil)
          @req.unprovided_inputs.read(:session, key, read)
        end
    end
  end
end
