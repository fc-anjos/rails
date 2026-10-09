# frozen_string_literal: true

require "helper"
require "jobs/hello_job"
require "models/person"
require "active_support/json"

class CarriedStateTest < ActiveSupport::TestCase
  class TenantJob < ActiveJob::Base
    def perform
      ActiveSupport::IsolatedExecutionState[:carried_state_test_tenant]
    end
  end

  setup do
    ActiveSupport::CarriedState.register :carried_state_test_tenant,
      capture: -> { ActiveSupport::IsolatedExecutionState[:carried_state_test_tenant] },
      restore: ->(tenant, &block) do
        ActiveSupport::IsolatedExecutionState[:carried_state_test_tenant] = tenant
        block.call
      ensure
        ActiveSupport::IsolatedExecutionState.delete(:carried_state_test_tenant)
      end
  end

  teardown do
    ActiveSupport::CarriedState.unregister(:carried_state_test_tenant)
    ActiveSupport::IsolatedExecutionState.delete(:carried_state_test_tenant)
  end

  test "a job captures registered values as it is created, serializes them, and restores them as it is performed" do
    ActiveSupport::IsolatedExecutionState[:carried_state_test_tenant] = Person.new(5)
    job_data = TenantJob.new.serialize
    ActiveSupport::IsolatedExecutionState.delete(:carried_state_test_tenant)

    job = ActiveJob::Base.deserialize(JSON.parse(job_data.to_json))

    assert_equal Person.new(5), job.perform_now
  end

  test "a job without registered values serializes none" do
    assert_not HelloJob.new.serialize.key?("carried_state")
  end

  test "a value that cannot cross a queue raises as the job is serialized" do
    ActiveSupport::IsolatedExecutionState[:carried_state_test_tenant] = Object.new

    assert_raises(ActiveJob::SerializationError) { TenantJob.new.serialize }
  end

  test "values of hooks not registered where the job is performed are ignored" do
    ActiveSupport::IsolatedExecutionState[:carried_state_test_tenant] = "acme"
    job_data = TenantJob.new.serialize
    ActiveSupport::CarriedState.unregister(:carried_state_test_tenant)
    ActiveSupport::IsolatedExecutionState.delete(:carried_state_test_tenant)

    assert_nil ActiveJob::Base.deserialize(job_data).perform_now
  end
end
