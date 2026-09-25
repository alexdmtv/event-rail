module Platform
  # Raised by a job the developer console told to fail. Demonstration only.
  class InjectedFault < StandardError; end
end
