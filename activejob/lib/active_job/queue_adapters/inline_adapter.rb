# frozen_string_literal: true

module ActiveJob
  module QueueAdapters
    # = Active Job Inline adapter
    #
    # When enqueuing jobs with the Inline adapter the job will be executed
    # immediately.
    #
    # The job runs on the calling thread. With
    # +config.active_job.isolate_inline_jobs+ enabled, it runs with its own
    # ActiveSupport::CurrentAttributes, as it would when performed by a queue,
    # and the caller's are put back once it finishes.
    #
    # To use the Inline set the queue_adapter config to +:inline+.
    #
    #   Rails.application.config.active_job.queue_adapter = :inline
    class InlineAdapter < AbstractAdapter
      def enqueue(job) # :nodoc:
        execute_inline(job.serialize)
      end

      def enqueue_at(*) # :nodoc:
        raise NotImplementedError, "Use a queueing backend to enqueue jobs in the future. Read more at https://guides.rubyonrails.org/active_job_basics.html"
      end
    end
  end
end
