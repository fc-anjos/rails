# frozen_string_literal: true

# :markup: markdown

module ActionController
  class Renderer
    # The flash of a render that was not given a session to read one from. It
    # reports its reads before answering them as an empty flash does. A message the
    # render sets, including through `flash.now`, is its own, and reading it back
    # is not reported.
    class WithheldFlash < ActionDispatch::Flash::FlashHash # :nodoc:
      def initialize(unprovided_inputs)
        super()
        @unprovided_inputs = unprovided_inputs
      end

      def [](key)
        unprovided_read key
        super
      end

      def key?(key)
        unprovided_read key
        super
      end

      def keys
        unprovided_read
        super
      end

      def to_hash
        unprovided_read
        super
      end

      def empty?
        unprovided_read
        super
      end

      def each(&)
        unprovided_read
        super
      end

      private
        def unprovided_read(key = nil)
          unless key && @flashes.key?(key.to_s)
            @unprovided_inputs.read(:flash, key)
          end
        end
    end
  end
end
