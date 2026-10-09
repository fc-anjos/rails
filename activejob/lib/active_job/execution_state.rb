# frozen_string_literal: true

module ActiveJob
  # Performs a job with the state registered with ActiveSupport::CarriedState
  # that it captured as it was created, including the locale and time zone,
  # which Active Job registers as it is required.
  module ExecutionState # :nodoc:
    def perform_now
      carried = carried_state.merge(locale: locale, timezone: timezone).compact
      ActiveSupport::CarriedState.restore(carried) { super }
    end
  end
end
