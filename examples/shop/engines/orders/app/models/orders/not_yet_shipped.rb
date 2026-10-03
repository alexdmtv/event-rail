module Orders
  class NotYetShipped < StandardError
    include Platform::Aborted
  end
end
