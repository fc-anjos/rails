# frozen_string_literal: true

# :markup: markdown

require "active_support/callbacks"

module ActionCable
  module Connection
    # # Action Cable Connection Callbacks
    #
    # The [before_command](rdoc-ref:ClassMethods#before_command),
    # [after_command](rdoc-ref:ClassMethods#after_command), and
    # [around_command](rdoc-ref:ClassMethods#around_command) callbacks are invoked
    # when receiving commands from the client, such as when subscribing,
    # unsubscribing, or performing an action.
    #
    # #### Example
    #
    # ```
    # module ApplicationCable
    #   class Connection < ActionCable::Connection::Base
    #     identified_by :user
    #
    #     around_command :set_current_account
    #
    #     private
    #
    #     def set_current_account
    #       # Now all channels could use Current.account
    #       Current.set(account: user.account) { yield }
    #     end
    #   end
    # end
    # ```
    #
    # Such a block holds the state of the user who sent the command, so renders
    # through ActionController::Renderer made during the command, such as Turbo
    # Stream broadcasts sent to other users, are not given the attributes it sets
    # (see `config.action_controller.action_on_unprovided_renderer_input`).
    #
    module Callbacks
      extend  ActiveSupport::Concern
      include ActiveSupport::Callbacks

      included do
        define_callbacks :command
      end

      module ClassMethods
        def before_command(*methods, &block)
          set_callback(:command, :before, *methods, &block)
        end

        def after_command(*methods, &block)
          set_callback(:command, :after, *methods, &block)
        end

        def around_command(*methods, &block)
          set_callback(:command, :around, *methods, &block)
        end
      end
    end
  end
end
