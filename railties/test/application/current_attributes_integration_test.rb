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
        get "/customers/set_current_customer", to: "customers#set_current_customer"
        get "/customers/set_no_customer", to: "customers#set_no_customer"
        get "/customers/perform_inline_job", to: "customers#perform_inline_job"
        get "/customers/broadcast", to: "customers#broadcast"
        get "/customers/broadcast_given", to: "customers#broadcast_given"
        get "/customers/broadcast_later", to: "customers#broadcast_later"
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

        def broadcast
          Current.customer = Customer.new("david")
          html = ApplicationController.render(partial: "customers/customer")
          render plain: "\#{html.strip}|\#{Current.customer.name},\#{Time.zone.name}"
        end

        def broadcast_given
          Current.customer = Customer.new("david")
          html = ApplicationController.render(partial: "customers/given_customer",
            locals: { customer: Customer.new("everyone") })
          render plain: "\#{html.strip}|\#{Current.customer.name},\#{Time.zone.name}"
        end

        def broadcast_later
          Current.customer = Customer.new("david")
          RenderCustomerJob.perform_later
          render plain: RenderCustomerJob.renders.join
        end

        def perform_inline_job
          Current.customer = Customer.new("david")
          RecordCustomerJob.perform_later
          render :index
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

    app_file "app/jobs/render_customer_job.rb", <<-RUBY
      class RenderCustomerJob < ActiveJob::Base
        cattr_accessor :renders, default: []

        def perform
          renders << ApplicationController.render(partial: "customers/customer").strip
        end
      end
    RUBY

    app_file "app/views/customers/_customer.html.erb", <<-RUBY
      <%= Current.customer&.name || 'noone' %>,<%= Time.zone.name %>
    RUBY

    app_file "app/views/customers/_given_customer.html.erb", <<-RUBY
      <%= customer.name %>,<%= Time.zone.name %>
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

  test "a render during a request reads the request's current attributes with 8.1 defaults" do
    boot_app "8.1"

    get "/customers/broadcast"

    assert_equal "david,Copenhagen|david,Copenhagen", last_response.body
  end

  test "a render during a request that reads a current attribute the request set raises with 8.2 defaults" do
    boot_app "8.2", "config.action_dispatch.show_exceptions = :none"

    error = assert_raises(ActionView::Template::Error) { get "/customers/broadcast" }
    assert_instance_of ActionController::Renderer::UnprovidedInputError, error.cause
    assert_match "`Current.customer` was read by a render of `customers/customer`", error.message
  end

  test "a render during a request starts with empty current attributes and keeps the time zone with 8.2 defaults" do
    boot_app "8.2", "config.action_controller.action_on_unprovided_renderer_input = :log"

    get "/customers/broadcast"

    assert_equal "noone,Copenhagen|david,Copenhagen", last_response.body
  end

  test "a render given its values as locals renders with them, and the request's attributes are kept, with 8.2 defaults" do
    boot_app "8.2"

    get "/customers/broadcast_given"

    assert_equal "everyone,Copenhagen|david,Copenhagen", last_response.body
  end

  test "a render in a job performed inline during a request is not reported with 8.2 defaults" do
    boot_app "8.2"

    get "/customers/broadcast_later"

    assert_equal "noone,Copenhagen", last_response.body
  end

  private
    def boot_app(defaults = nil, config = nil)
      if defaults
        remove_from_config '.*config\.load_defaults.*\n'
        add_to_config "config.load_defaults #{defaults.inspect}"
      end
      add_to_config config if config

      require "#{app_path}/config/environment"
    end

    # Loading ActiveSupport::TestCase with executor_around_test_case makes
    # execution contexts nest. Outside of tests, in a Rake task for example,
    # they do not.
    def outside_of_tests
      ActiveSupport::ExecutionContext.nestable = false
    end
end
