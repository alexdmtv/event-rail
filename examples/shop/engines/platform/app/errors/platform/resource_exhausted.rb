module Platform
  # Error category: a rate limit or quota. Retried with backoff; HTTP 429.
  module ResourceExhausted; end
end
