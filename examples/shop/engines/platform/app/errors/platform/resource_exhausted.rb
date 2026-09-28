module Platform
  # Error category: a rate limit or quota; tried again later. Retried with a longer wait; HTTP 429. See Platform::ErrorCategory.
  module ResourceExhausted; end
end
