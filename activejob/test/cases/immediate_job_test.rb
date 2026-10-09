# frozen_string_literal: true

require "helper"

class ImmediateJobTest < ActiveSupport::TestCase
  module CarriesTenant
    def serialize
      super.merge("tenant" => ActiveSupport::IsolatedExecutionState[:immediate_job_test_tenant])
    end

    def deserialize(job_data)
      super
      @tenant = job_data["tenant"]
    end

    def perform_now
      ActiveSupport::IsolatedExecutionState[:immediate_job_test_tenant] = @tenant
      super
    end
  end

  test "a block performed in isolation receives the locale and time zone a job receives" do
    I18n.available_locales, available_locales = [:en, :de], I18n.available_locales
    captured = I18n.with_locale(:de) { Time.use_zone("Tokyo") { ActiveJob::ImmediateJob.capture } }

    result = ActiveSupport::IsolatedExecutionState.isolated do
      captured.perform { [I18n.locale, Time.zone.name] }
    end

    assert_equal [:de, "Tokyo"], result
  ensure
    I18n.available_locales = available_locales
  end

  test "a block performed in isolation receives what a library carries into every job" do
    job_class = Class.new(ActiveJob::ImmediateJob) { prepend CarriesTenant }
    stub_const(ActiveJob, :ImmediateJob, job_class) do
      ActiveSupport::IsolatedExecutionState[:immediate_job_test_tenant] = "acme"
      captured = ActiveJob::ImmediateJob.capture

      tenant = ActiveSupport::IsolatedExecutionState.isolated do
        captured.perform { ActiveSupport::IsolatedExecutionState[:immediate_job_test_tenant] }
      end

      assert_equal "acme", tenant
    ensure
      ActiveSupport::IsolatedExecutionState.delete(:immediate_job_test_tenant)
    end
  end

  test "the block is not serialized" do
    object = Object.new
    captured = ActiveJob::ImmediateJob.capture

    assert_same object, captured.perform { object }
  end
end
