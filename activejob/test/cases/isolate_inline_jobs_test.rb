# frozen_string_literal: true

require "helper"
require "active_support/core_ext/object/with"

module IsolateInlineJobsTestHelper
  extend ActiveSupport::Concern

  class Current < ActiveSupport::CurrentAttributes
    attribute :user
  end

  # Its writer has a side effect outside the class, as acts_as_tenant's
  # tenant_change_hook setting a database session variable. Active Job performs
  # each job in the time zone it was enqueued in, which puts back a Time.zone
  # set by a writer on its own.
  class Tenant < ActiveSupport::CurrentAttributes
    attribute :tenant

    singleton_class.attr_accessor :connection_tenant

    def tenant=(tenant)
      super
      self.class.connection_tenant = tenant
    end
  end

  # The test adapter replaces this adapter in ActiveJob::TestCase.
  class InlineJob < ActiveJob::Base
    self.queue_adapter = :inline
  end

  class CurrentUserJob < InlineJob
    def perform(new_user = nil)
      JobBuffer.add(Current.user)
      JobBuffer.add(ActiveSupport::ExecutionContext.to_h[:controller])
      Current.user = new_user if new_user
    end
  end

  class RaisingCurrentUserJob < InlineJob
    def perform
      Current.user = "job"
      Tenant.tenant = "job"
      raise ArgumentError, "job failed"
    end
  end

  class TenantJob < InlineJob
    def perform(tenant)
      JobBuffer.add(Tenant.tenant)
      Tenant.tenant = tenant
    end
  end

  class NestingTenantJob < InlineJob
    def perform
      Tenant.tenant = "job"
      TenantJob.perform_later("inner")
      JobBuffer.add(ActiveSupport::ExecutionContext.to_h[:job].class)
      JobBuffer.add(Tenant.tenant)
      JobBuffer.add(Tenant.connection_tenant)
    end
  end

  included do
    setup do
      JobBuffer.clear
      ActiveSupport::ExecutionContext.clear
      ActiveSupport::ExecutionContext[:controller] = "PostsController"
      Current.user = "caller"
    end

    teardown do
      Current.reset
      Tenant.connection_tenant = nil
      ActiveSupport::ExecutionContext.clear
    end
  end
end

class IsolateInlineJobsTest < ActiveSupport::TestCase
  include IsolateInlineJobsTestHelper

  test "an inline job shares the caller's CurrentAttributes and execution context by default" do
    CurrentUserJob.perform_later("job")

    assert_equal ["caller", "PostsController"], JobBuffer.values
    assert_equal "job", Current.user
  end

  test "an inline job runs with its own CurrentAttributes and execution context when isolate_inline_jobs is enabled" do
    ActiveJob.with(isolate_inline_jobs: true) do
      CurrentUserJob.perform_later("job")
    end

    assert_equal [nil, nil], JobBuffer.values
    assert_equal "caller", Current.user
    assert_equal({ controller: "PostsController" }, ActiveSupport::ExecutionContext.to_h)
  end

  test "an inline job that raises restores the caller's CurrentAttributes when isolate_inline_jobs is enabled" do
    Tenant.tenant = "caller"

    ActiveJob.with(isolate_inline_jobs: true) do
      assert_raises(ArgumentError) { RaisingCurrentUserJob.perform_later }
    end

    assert_equal "caller", Current.user
    assert_equal "caller", Tenant.connection_tenant
    assert_equal({ controller: "PostsController" }, ActiveSupport::ExecutionContext.to_h)
  end

  test "an inline job's writes are set back through the caller's writers when isolate_inline_jobs is enabled" do
    Tenant.tenant = "caller"

    ActiveJob.with(isolate_inline_jobs: true) do
      TenantJob.perform_later("job")
    end

    assert_equal [nil], JobBuffer.values
    assert_equal "caller", Tenant.tenant
    assert_equal "caller", Tenant.connection_tenant
  end

  test "an inline job performed by a job restores the outer job's execution context and writes when isolate_inline_jobs is enabled" do
    Tenant.tenant = "caller"

    ActiveJob.with(isolate_inline_jobs: true) do
      NestingTenantJob.perform_later
    end

    assert_equal [nil, NestingTenantJob, "job", "job"], JobBuffer.values
    assert_equal "caller", Tenant.tenant
    assert_equal "caller", Tenant.connection_tenant
  end
end

class IsolateTestAdapterJobsTest < ActiveJob::TestCase
  include IsolateInlineJobsTestHelper

  def queue_adapter_for_test
    ActiveJob::QueueAdapters::TestAdapter.new
  end

  test "perform_enqueued_jobs with a block shares the caller's CurrentAttributes by default" do
    perform_enqueued_jobs { CurrentUserJob.perform_later("job") }

    assert_equal ["caller", "PostsController"], JobBuffer.values
    assert_equal "job", Current.user
  end

  test "perform_enqueued_jobs with a block runs jobs with their own CurrentAttributes when isolate_inline_jobs is enabled" do
    ActiveJob.with(isolate_inline_jobs: true) do
      perform_enqueued_jobs { CurrentUserJob.perform_later("job") }
    end

    assert_equal [nil, nil], JobBuffer.values
    assert_equal "caller", Current.user
  end

  test "the test adapter performing enqueued jobs runs them with their own CurrentAttributes when isolate_inline_jobs is enabled" do
    queue_adapter.perform_enqueued_jobs = true

    ActiveJob.with(isolate_inline_jobs: true) do
      CurrentUserJob.perform_later("job")
    end

    assert_equal [nil, nil], JobBuffer.values
    assert_equal "caller", Current.user
  end

  test "perform_enqueued_jobs without a block shares the caller's CurrentAttributes by default" do
    CurrentUserJob.perform_later("job")
    perform_enqueued_jobs

    assert_equal ["caller", "PostsController"], JobBuffer.values
    assert_equal "job", Current.user
  end

  test "perform_enqueued_jobs without a block runs jobs with their own CurrentAttributes when isolate_inline_jobs is enabled" do
    CurrentUserJob.perform_later("job")

    ActiveJob.with(isolate_inline_jobs: true) do
      perform_enqueued_jobs
    end

    assert_equal [nil, nil], JobBuffer.values
    assert_equal "caller", Current.user
    assert_performed_jobs 1
  end
end
