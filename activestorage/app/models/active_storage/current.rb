# frozen_string_literal: true

class ActiveStorage::Current < ActiveSupport::CurrentAttributes # :nodoc:
  attribute :url_options

  # URL options are the same for every user, so renders isolated from the
  # request's attributes still build blob URLs with them.
  ActiveSupport::CurrentAttributes::Isolation.carry(self, :url_options)
end
