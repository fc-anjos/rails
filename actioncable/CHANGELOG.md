*   Check renders through `ActionController::Renderer` made during channel commands.

    A Turbo Stream broadcast rendered while a channel subscribes, unsubscribes
    or performs an action, such as one an `after_create_commit` callback sends,
    is checked for `Current` attributes it was not given, as
    `config.action_controller.action_on_unprovided_renderer_input` decides for
    controller actions. A `Current.set` block that an `around_command` opens
    holds the state of the user who sent the command, and provides nothing to it.

    ```ruby
    class ChatChannel < ApplicationCable::Channel
      def speak(data)
        Current.set(user: nil) do
          Message.create!(body: data["body"]) # its broadcast renders with no user
        end
      end
    end
    ```

    `ActionCable::Channel::TestCase` checks `subscribe` and `perform` as commands
    too. With `:raise`, which `config.load_defaults "8.2"` sets, a channel test
    that assigns a `Current` attribute and performs an action whose render reads
    it raises, as that render would in production with the attribute set by an
    `around_command`. Provide the attribute where the render is made, with
    `Current.set` or as a local, or, if the application does not set it during
    commands, stop assigning it in the test.

    *Felipe Cavalheiro Anjos*

*   Move `ActionCable::Server::Configuration` to `ActionCable::Configuration`.

    The old constant remains available as an alias.

    *Samuel Williams*

*   Respect calls to `#reject` in `before_subscribe` callbacks.

    It doesn't call `#subscribed` if a `before_subscribe` callback calls `#reject`.

    *Joshua Young*

*   Extract low-level Action Cable server responsibilities into `ActionCable::Server`
    abstractions.

    This refactoring separates socket handling, concurrency primitives, and
    other transport-specific behavior from application-level connections and
    channels. It makes Action Cable more flexible as a framework and opens the
    door to alternative server implementations without changing user-facing
    channel and connection code.

    *Vladimir Dementyev*

*   Fix Action Cable origin check to respect `X-Forwarded-Host` behind reverse proxies.

    The `allow_same_origin_as_host` check previously compared against the raw
    `HTTP_HOST` header, which fails when a proxy forwards requests with a
    different internal host. It now uses `request.host_with_port`, consistent
    with the rest of Rails.

    *Jordan Brough*

*   Channel generator now detects which JS package manager to use when
    installing javascript dependencies.

    *David Lowenfels*

Please check [8-1-stable](https://github.com/rails/rails/blob/8-1-stable/actioncable/CHANGELOG.md) for previous changes.
