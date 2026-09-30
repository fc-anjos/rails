# frozen_string_literal: true

require "isolation/abstract_unit"
require "rack/test"

class CurrentAttributesIntegrationTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::Isolation
  include Rack::Test::Methods

  setup do
    build_app

    app_file "app/models/current.rb", <<-RUBY
      class Current < ActiveSupport::CurrentAttributes
        attribute :customer

        resets { Time.zone = "UTC" }

        def customer=(customer)
          super
          Time.zone = customer&.time_zone
        end
      end
    RUBY

    app_file "app/models/customer.rb", <<-RUBY
      class Customer < Struct.new(:name)
        def time_zone
          "Copenhagen"
        end
      end
    RUBY

    app_file "config/routes.rb", <<-RUBY
      Rails.application.routes.draw do
        get "/customers/:action", controller: :customers
      end
    RUBY

    app_file "app/controllers/customers_controller.rb", <<-RUBY
      class CustomersController < ApplicationController
        layout false

        def set_current_customer
          Current.customer = Customer.new("david")
          render :index
        end

        def set_no_customer
          render :index
        end

        def perform_inline_job
          Current.customer = Customer.new("david")
          RecordCustomerJob.perform_later
          render :index
        end

        def render_in_inline_job
          Current.customer = Customer.new("david")
          RenderCustomerJob.perform_later
          render :index
        end

        def render_with_renderer
          Current.customer = Customer.new("david")
          render plain: ApplicationController.render(partial: "customers/customer")
        rescue ActionView::Template::Error => error
          render plain: error.cause.class.name
        end
      end
    RUBY

    app_file "app/models/message.rb", <<-RUBY
      class Message < ActiveRecord::Base
        attr_accessor :rendered

        after_create_commit do
          self.rendered = self.class.render_customer
        end

        def self.render_customer
          ApplicationController.render(partial: "customers/customer").strip
        rescue ActionView::Template::Error => error
          error.cause.class.name
        end
      end
    RUBY

    app_file "app/jobs/record_customer_job.rb", <<-RUBY
      class RecordCustomerJob < ActiveJob::Base
        cattr_accessor :customers, default: []

        def perform
          customers << Current.customer&.name
        end
      end
    RUBY

    app_file "app/channels/application_cable/connection.rb", <<-RUBY
      module ApplicationCable
        class Connection < ActionCable::Connection::Base
          around_command :set_current_customer

          private
            def set_current_customer(&)
              Current.set(customer: Customer.new("david"), &)
            end
        end
      end
    RUBY

    app_file "app/channels/messages_channel.rb", <<-RUBY
      class MessagesChannel < ActionCable::Channel::Base
        cattr_accessor :rendered, default: []

        def speak
          rendered << Message.create!.rendered
        end
      end
    RUBY

    app_file "app/jobs/render_customer_job.rb", <<-RUBY
      class RenderCustomerJob < ActiveJob::Base
        cattr_accessor :rendered, default: []

        def perform
          rendered << ApplicationController.render(partial: "customers/customer")
        end
      end
    RUBY

    app_file "app/views/customers/_customer.html.erb", <<-RUBY
      <%= Current.customer&.name || 'noone' %>
    RUBY

    add_to_config "config.active_job.queue_adapter = :inline"

    app_file "app/views/customers/index.html.erb", <<-RUBY
      <%= Current.customer&.name || 'noone' %>,<%= Time.zone.name %>
    RUBY
  end

  teardown :teardown_app

  test "current customer is assigned and cleared" do
    boot_app
    get "/customers/set_current_customer"
    assert_equal 200, last_response.status
    assert_match(/david,Copenhagen/, last_response.body)

    get "/customers/set_no_customer"
    assert_equal 200, last_response.status
    assert_match(/noone,UTC/, last_response.body)
  end

  test "resets after execution" do
    boot_app

    assert_nil Current.customer
    assert_equal "UTC", Time.zone.name

    Rails.application.executor.wrap do
      Current.customer = Customer.new("david")

      assert_equal "david", Current.customer.name
      assert_equal "Copenhagen", Time.zone.name
    end

    assert_nil Current.customer
    assert_equal "UTC", Time.zone.name
  end

  test "a job performed inline during a request starts with empty current attributes" do
    boot_app "8.2"

    get "/customers/perform_inline_job"

    assert_equal 200, last_response.status
    assert_match(/david,Copenhagen/, last_response.body)
    assert_equal [nil], RecordCustomerJob.customers
  end

  test "a job performed inline outside of the executor keeps the caller's current attributes and what their writers set" do
    boot_app "8.2"
    outside_of_tests

    Current.customer = Customer.new("david")
    RecordCustomerJob.perform_later

    assert_equal [nil], RecordCustomerJob.customers
    assert_equal "david", Current.customer.name
    assert_equal "Copenhagen", Time.zone.name
  end

  test "a render through the renderer during a request raises when it reads the request's current attributes" do
    boot_app "8.2"

    get "/customers/render_with_renderer"

    assert_equal 200, last_response.status
    assert_equal "ActionController::Renderer::UnprovidedInputError", last_response.body
  end

  test "a render through the renderer during a channel action raises when it reads what an around_command's set block holds" do
    boot_app "8.2"
    Message.lease_connection.create_table(:messages)

    perform_channel_action "speak"

    assert_equal ["ActionController::Renderer::UnprovidedInputError"], MessagesChannel.rendered
  end

  test "a render in a job performed inline during a request is not checked against the request" do
    boot_app "8.2"

    get "/customers/render_in_inline_job"

    assert_equal 200, last_response.status
    assert_match(/david,Copenhagen/, last_response.body)
    assert_equal ["noone"], RenderCustomerJob.rendered.map(&:strip)
  end

  private
    # Subscribes to MessagesChannel and performs +action+, each command through
    # the Action Cable worker pool, as the server processes it.
    def perform_channel_action(action)
      server = ActionCable.server
      env = Rack::MockRequest.env_for("/cable", "HTTP_HOST" => "localhost", "HTTP_CONNECTION" => "upgrade", "HTTP_UPGRADE" => "websocket")
      connection = ApplicationCable::Connection.new(server, ActionCable::Server::Socket.new(server, env))
      identifier = { channel: "MessagesChannel" }.to_json

      [{ "command" => "subscribe", "identifier" => identifier },
       { "command" => "message", "identifier" => identifier, "data" => { action: action }.to_json }].each do |payload|
        server.worker_pool.invoke(connection, :handle_channel_command, payload, connection: connection)
      end
    end

    def boot_app(defaults = nil)
      if defaults
        remove_from_config '.*config\.load_defaults.*\n'
        add_to_config "config.load_defaults #{defaults.inspect}"
      end

      require "#{app_path}/config/environment"
    end

    # Loading ActiveSupport::TestCase with executor_around_test_case makes
    # execution contexts nest. Outside of tests, in a Rake task for example,
    # they do not.
    def outside_of_tests
      ActiveSupport::ExecutionContext.nestable = false
    end
end
