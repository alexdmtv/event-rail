module Orders
  class Order
    module Returnable
      extend ActiveSupport::Concern

      RETURN_WINDOW = 14.days

      included do
        has_one :return, dependent: :destroy
      end

      def returnable? = within_return_window? && !cancelled? && self.return.nil?

      # Safe to repeat: returns the existing return, even once the window has closed.
      def request_return
        with_lock do
          next self.return if self.return
          raise NotReturnable, not_returnable_reason unless returnable?

          create_return!(state: "requested").tap(&:collect_later)
        end
      end

      private
        def within_return_window? = delivered_at.present? && delivered_at > RETURN_WINDOW.ago

        def not_returnable_reason
          if delivered_at.nil? then "order #{id} has not been delivered"
          else "order #{id} was delivered more than #{RETURN_WINDOW.inspect} ago"
          end
        end
    end
  end
end
