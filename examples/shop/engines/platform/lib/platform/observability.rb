module Platform
  # The context every error report and structured event of a request or job carries. Rails keeps
  # one store for each, and clears both when the request or job ends.
  module Observability
    def self.set_context(**context)
      Rails.error.set_context(**context)
      Rails.event.set_context(context)
    end
  end
end
