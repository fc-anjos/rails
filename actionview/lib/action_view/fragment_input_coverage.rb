# frozen_string_literal: true

require "active_support/current_attributes"
require "active_support/isolated_execution_state"

module ActionView
  # Raised when a fragment cached with ActionView::Helpers::CacheHelper#cache read
  # an input that its cache key does not cover, and
  # `config.action_view.action_on_uncovered_fragment_input` is `:raise`.
  class UncoveredFragmentInputError < ActionViewError
  end

  # Checks that the key given to ActionView::Helpers::CacheHelper#cache covers
  # what rendering the fragment read: request input and params, published as
  # `read_input.action_dispatch` events, Current attributes, and the locale that
  # the translation helpers used.
  #
  # Checks are frames on a stack, one for each fragment rendering on this thread
  # or fiber; a read counts for every open frame, since an outer fragment holds
  # the output of the inner ones.
  module FragmentInputCoverage # :nodoc:
    READ_INPUT_EVENT = "read_input.action_dispatch"
    FRAMES = :action_view_fragment_input_frames
    ACTIONS = [false, nil, :log, :raise].freeze

    Read = Struct.new(:input, :key, :value) do
      # A read with no key read a whole session, cookie jar or flash, a CSRF token or
      # a nonce, which no value in a cache key stands for. Values are compared with
      # +eql?+, which converts neither side, so that comparing an array read to a
      # relation in the key does not load the relation.
      def covered_by?(key_parts)
        !key.nil? && key_parts.any? { |part| value.eql?(part) }
      end

      def description
        case input
        when :current_attributes, :locale then "`#{key}` (#{value.class})"
        when :csrf_token then "the CSRF token"
        when :csp_nonce then "the content security policy nonce"
        else key ? "`#{input}[#{key.inspect}]` (#{value.class})" : "the whole #{input}"
        end
      end
    end

    @action = false
    @subscriber = nil

    class << self
      attr_reader :action

      def action=(action)
        unless ACTIONS.include?(action)
          raise ArgumentError, "config.action_view.action_on_uncovered_fragment_input must be false, :log or :raise, got #{action.inspect}"
        end

        if action && !@subscriber
          @subscriber = ActiveSupport::Notifications.subscribe(READ_INPUT_EVENT) do |_name, _start, _finish, _id, payload|
            record(payload[:input], payload[:key], payload[:value])
          end
        elsif !action && @subscriber
          ActiveSupport::Notifications.unsubscribe(@subscriber)
          @subscriber = nil
        end

        @action = action
      end

      # Returns the fragment the block renders, after logging or raising for the
      # inputs it read that +key+, the key given to +cache+, does not cover.
      def check(key, template, logger, &block)
        frame = []
        frames = (ActiveSupport::IsolatedExecutionState[FRAMES] ||= [])
        frames.push(frame)

        record_current_read = ->(current, name, value) do
          frame << Read.new(:current_attributes, "#{current.class.name}.#{name}", value)
        end

        fragment = begin
          ActiveSupport::CurrentAttributes.observing_reads(record_current_read, only_set: false, &block)
        ensure
          frames.pop
          # A thread spawned by ActionController::Live starts with a shallow copy of
          # this state, so an empty stack left behind would be shared with it.
          ActiveSupport::IsolatedExecutionState.delete(FRAMES) if frames.empty?
        end

        key_parts = flatten_key(key)
        uncovered = frame.reject { |read| read.covered_by?(key_parts) }.uniq { |read| [read.input, read.key] }
        report(uncovered, key, template, logger) unless uncovered.empty?

        fragment
      end

      # Records the locale that translating or localizing used while a fragment is
      # rendering, unless the application has a single locale.
      def record_locale
        if @action && checking? && !I18n.available_locales.one?
          record(:locale, "I18n.locale", I18n.locale)
        end
      end

      private
        def checking?
          frames = ActiveSupport::IsolatedExecutionState[FRAMES]
          frames && !frames.empty?
        end

        def record(input, key, value)
          if checking?
            read = Read.new(input, key, value)
            ActiveSupport::IsolatedExecutionState[FRAMES].each { |frame| frame << read }
          end
        end

        # Only literal arrays and hashes are flattened: a relation in a key stands
        # for its cache key, and is not loaded to be compared.
        def flatten_key(key, parts = [])
          case key
          when Array then key.each { |part| flatten_key(part, parts) }
          when Hash then key.each_value { |part| flatten_key(part, parts) }
          else parts << key
          end

          parts
        end

        def report(uncovered, key, template, logger)
          message = +"The fragment cached"
          message << " in #{template.short_identifier}" if template
          message << " with the key #{ActiveSupport::Cache.expand_cache_key(key).inspect}" \
            " read #{uncovered.map(&:description).to_sentence(locale: false)}, which the key does not include." \
            " Requests that read different values would be served this fragment from the cache." \
            " Add each value read to the key given to `cache`, or read it outside the `cache` block." \
            " A CSRF token, a nonce, or a whole session, cookie jar or flash cannot be part of a key" \
            " and must be read outside the block."

          case action
          when :raise
            raise UncoveredFragmentInputError, message
          when :log
            logger&.warn(message)
          end
        end
    end
  end
end
