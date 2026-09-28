module Platform
  # Each module's own ApplicationRecord inherits from this one, which is the application's
  # single primary abstract class.
  class ApplicationRecord < ActiveRecord::Base
    primary_abstract_class

    private
      # Makes the change if the row still meets the condition, in one statement, so that a
      # step repeated or raced by another process changes the row once; true if this call made
      # the change. The record is reloaded either way. For a model's own transition methods.
      def update_if(condition, **attributes)
        changed = self.class.where(id: id).where(condition).update_all(attributes.merge(updated_at: Time.current))
        reload
        changed == 1
      end
  end
end
