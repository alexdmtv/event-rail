module Platform
  class ApplicationRecord < ActiveRecord::Base
    primary_abstract_class

    private
      # One conditional statement, so a repeated or raced step changes the row once; true if
      # this call made the change, and the record is reloaded either way. The block runs only
      # then, in the same transaction.
      def update_if(condition, **attributes, &block)
        return change_if(condition, attributes) unless block

        transaction { change_if(condition, attributes).tap { |changed| yield if changed } }
      end

      def change_if(condition, attributes)
        changed = self.class.where(id: id).where(condition).update_all(attributes.merge(updated_at: Time.current))
        reload
        changed == 1
      end
  end
end
