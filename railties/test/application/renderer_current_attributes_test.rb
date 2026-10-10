# frozen_string_literal: true

require "isolation/abstract_unit"
require "rack/test"

class RendererCurrentAttributesTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::Isolation
  include Rack::Test::Methods

  setup do
    build_app

    add_to_config "config.action_controller.action_on_current_attribute_read_in_renderer = :raise"
    add_to_config "config.consider_all_requests_local = false"
    add_to_config "config.action_dispatch.show_exceptions = :none"

    app_file "app/models/current.rb", <<-RUBY
      class Current < ActiveSupport::CurrentAttributes
        attribute :user
      end
    RUBY

    app_file "config/routes.rb", <<-RUBY
      Rails.application.routes.draw do
        get "/messages/broadcast", to: "messages#broadcast"
        get "/messages/broadcast_to_nobody", to: "messages#broadcast_to_nobody"
      end
    RUBY

    app_file "app/controllers/messages_controller.rb", <<-RUBY
      class MessagesController < ApplicationController
        before_action { Current.user = "david" }

        def broadcast
          BroadcastJob.perform_later
          head :ok
        end

        def broadcast_to_nobody
          Current.set(user: nil) { BroadcastJob.perform_later }
          head :ok
        end
      end
    RUBY

    app_file "app/jobs/broadcast_job.rb", <<-RUBY
      class BroadcastJob < ActiveJob::Base
        cattr_accessor :rendered

        def perform
          self.class.rendered = ApplicationController.render(partial: "messages/message")
        end
      end
    RUBY

    app_file "app/views/messages/_message.html.erb", <<-ERB
      <p><%= Current.user || "signed out" %></p>
    ERB
  end

  teardown :teardown_app

  def app
    Rails.application
  end

  test "a job performed inline during the action reports the request's attributes" do
    add_to_config "config.active_job.queue_adapter = :inline"
    require "#{app_path}/config/environment"

    error = assert_raises(ActionView::Template::Error) { get "/messages/broadcast" }
    assert_instance_of ActionController::Renderer::CurrentAttributeReadError, error.cause
    assert_match "`Current.user` was read by `messages/_message.html.erb:1`, rendered through " \
      "ActionController::Renderer during `MessagesController#broadcast`", error.cause.message
  end

  test "a job the test adapter performs during the action reports the request's attributes" do
    add_to_config "config.active_job.queue_adapter = :test"
    require "#{app_path}/config/environment"
    ActiveJob::Base.queue_adapter.perform_enqueued_jobs = true

    error = assert_raises(ActionView::Template::Error) { get "/messages/broadcast" }
    assert_instance_of ActionController::Renderer::CurrentAttributeReadError, error.cause
  end

  test "a job performed inside a set block opened during the action is given its attributes" do
    add_to_config "config.active_job.queue_adapter = :inline"
    require "#{app_path}/config/environment"

    get "/messages/broadcast_to_nobody"
    assert_equal 200, last_response.status
    assert_equal "<p>signed out</p>", BroadcastJob.rendered.strip
  end

  test "a job performed after the request is not checked" do
    add_to_config "config.active_job.queue_adapter = :test"
    require "#{app_path}/config/environment"

    get "/messages/broadcast"
    assert_equal 200, last_response.status

    Current.user = "david"
    BroadcastJob.perform_now
    assert_equal "<p>david</p>", BroadcastJob.rendered.strip
  end
end
