# frozen_string_literal: true

module ActiveJob
  # Runs a block as a job performed right away, so it receives from its caller
  # what a job enqueued by the caller receives as it is performed: the locale,
  # the time zone, and whatever libraries carry into every job by extending
  # ActiveJob::Base, such as a tenant. Nothing else reaches it.
  #
  # The job is serialized in the caller's state and deserialized where the block
  # runs, as a queue would, so a library that captures its state as the job is
  # created or as it is serialized is honored. The block is not an argument and
  # is never serialized.
  class ImmediateJob < Base # :nodoc:
    def self.capture
      Captured.new(self, new.serialize)
    end

    Captured = Struct.new(:job_class, :job_data) do # :nodoc:
      def perform(&block)
        job = job_class.new
        job.deserialize(job_data)
        job.body = block
        job.perform_now
      end
    end

    attr_writer :body

    def perform
      @body.call
    end
  end
end
