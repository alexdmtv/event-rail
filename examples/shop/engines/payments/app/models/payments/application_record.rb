module Payments
  class ApplicationRecord < Platform::ApplicationRecord
    self.abstract_class = true
  end
end
