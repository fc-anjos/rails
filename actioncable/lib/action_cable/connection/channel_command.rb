# frozen_string_literal: true

# :markup: markdown

module ActionCable
  module Connection
    # A command that a connection processes for its client: subscribing to a
    # channel, performing a channel action, or unsubscribing. It is kept in
    # ActiveSupport::ExecutionContext while it is processed, so that renders
    # through ActionController::Renderer can tell the `Current.set` blocks that
    # hold the client's state, such as one an `around_command` opens, from those
    # that provide attributes to them: the blocks opened before the channel calls
    # the action method, `subscribed` or `unsubscribed`, and still open, hold it.
    class ChannelCommand # :nodoc:
      class << self
        def current
          ActiveSupport::ExecutionContext[:channel_command]
        end

        def current=(command)
          ActiveSupport::ExecutionContext[:channel_command] = command
        end
      end

      # The number of `Current.set` blocks opened on the thread or fiber before the
      # channel calls the action method, or, until it does, before the command
      # started (see ActiveSupport::CurrentAttributes.opened_set_blocks).
      attr_reader :set_blocks_opened_before_action

      # Takes the payload of the command a connection received, or, for one the
      # channel processes on its own, the channel and the action.
      def initialize(payload = nil, channel: nil, action: nil)
        @payload = payload
        @channel = channel
        @action = action
        @set_blocks_opened_before_action = ActiveSupport::CurrentAttributes.opened_set_blocks
      end

      # Called where +channel+ calls +action+.
      def reach_action_line(channel, action)
        @channel = channel
        @action = action
        @set_blocks_opened_before_action = ActiveSupport::CurrentAttributes.opened_set_blocks
      end

      def processed_action_description
        "the channel action `#{channel_name}##{action_name}`"
      end

      private
        def channel_name
          if @channel
            @channel.class.name
          else
            decode(@payload["identifier"])["channel"]
          end
        end

        def action_name
          @action ||
            case @payload["command"]
            when "subscribe" then "subscribed"
            when "unsubscribe" then "unsubscribed"
            else decode(@payload["data"])["action"].presence || "receive"
            end
        end

        def decode(json)
          decoded = ActiveSupport::JSON.decode(json.to_s)
          Hash === decoded ? decoded : {}
        rescue JSON::ParserError
          {}
        end
    end
  end
end
