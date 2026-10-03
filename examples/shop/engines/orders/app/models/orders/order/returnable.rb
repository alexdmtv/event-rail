module Orders
  class Order
    module Returnable
      extend ActiveSupport::Concern

      included do
        has_many :returns, dependent: :destroy
      end

      # Safe to repeat: returns the existing return, even once the window has closed.
      def request_return
        with_lock do
          next returns.first if returns.any?
          raise NotReturnable, not_returnable_reason unless returnable?

          returns.create!(state: "requested").tap(&:collect_later)
        end
      end

      private
        def not_returnable_reason
          if delivered_at.nil? then "order #{id} has not been delivered"
          else "order #{id} was delivered more than #{RETURN_WINDOW.inspect} ago"
          end
        end
    end
  end
end
