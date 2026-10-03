module Platform
  # Error category: a temporary failure. Retried with backoff; HTTP 503.
  module Unavailable; end
end
