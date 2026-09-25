module Platform
  # Each module's own ApplicationRecord inherits from this one, which is the application's
  # single primary abstract class.
  class ApplicationRecord < ActiveRecord::Base
    primary_abstract_class
  end
end
