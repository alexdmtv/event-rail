module Orders
  class Order
    # A delivered order coming back, whole, within its return window. The return is an
    # aggregate of its own: the order checks its own rules and creates it, and from then on the
    # return lives its own life (Orders::Return).
    module Returnable
      extend ActiveSupport::Concern

      included do
        has_many :returns, dependent: :destroy
      end

      # A request repeated for an order already coming back returns that return: the window
      # applies to the first request.
      def request_return
        Flow.continue(self, step: "return") do
          with_lock do
            next returns.first if returns.any?
            raise NotReturnable, not_returnable_reason unless returnable?

            returns.create!(state: "requested").tap(&:collect_later)
          end
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
