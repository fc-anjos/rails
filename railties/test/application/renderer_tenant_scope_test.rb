# frozen_string_literal: true

require "isolation/abstract_unit"
require "rack/test"

class RendererTenantScopeTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::Isolation
  include Rack::Test::Methods

  setup do
    build_app

    app_file "app/models/current.rb", <<-RUBY
      class Current < ActiveSupport::CurrentAttributes
        attribute :account
      end
    RUBY

    app_file "app/models/account.rb", <<-RUBY
      class Account < ActiveRecord::Base
      end
    RUBY

    app_file "app/models/project.rb", <<-RUBY
      class Project < ActiveRecord::Base
        default_scope { where(account_id: Current.account.id) if Current.account }
      end
    RUBY

    app_file "config/routes.rb", <<-RUBY
      Rails.application.routes.draw do
        get "/accounts/:account_id/projects", to: "projects#index"
      end
    RUBY

    app_file "app/controllers/projects_controller.rb", <<-RUBY
      class ProjectsController < ApplicationController
        def index
          Current.account = Account.find(params[:account_id])
          html = ApplicationController.render(partial: "projects/projects")
          render plain: "\#{html.strip}|\#{Project.pluck(:name).join(",")}"
        end
      end
    RUBY

    app_file "app/views/projects/_projects.html.erb", <<-RUBY
      <%= Project.order(:id).pluck(:name).join(",") %>
    RUBY
  end

  teardown :teardown_app

  test "a render during a request lists the request's account's records with 8.1 defaults" do
    boot_app "8.1"

    get "/accounts/#{@acme.id}/projects"

    assert_equal "acme-1,acme-2|acme-1,acme-2", last_response.body
  end

  test "an isolated render during a request lists every account's records with 8.2 defaults" do
    boot_app "8.2", "config.action_controller.action_on_unprovided_renderer_input = :log"

    get "/accounts/#{@acme.id}/projects"

    assert_equal "acme-1,acme-2,globex-1|acme-1,acme-2", last_response.body
  end

  private
    def boot_app(defaults, config = nil)
      remove_from_config '.*config\.load_defaults.*\n'
      add_to_config "config.load_defaults #{defaults.inspect}"
      add_to_config config if config

      require "#{app_path}/config/environment"

      ActiveRecord::Migration.suppress_messages do
        ActiveRecord::Schema.define do
          create_table(:accounts) { |t| t.string :name }
          create_table(:projects) { |t| t.integer :account_id; t.string :name }
        end
      end

      @acme = Account.create!(name: "acme")
      globex = Account.create!(name: "globex")
      Project.create!(account_id: @acme.id, name: "acme-1")
      Project.create!(account_id: @acme.id, name: "acme-2")
      Project.create!(account_id: globex.id, name: "globex-1")
    end
end
