module Platform
  # Error category: temporary; the call is tried again. Retried with backoff; HTTP 503. See Platform::ErrorCategory.
  module Unavailable; end
end
