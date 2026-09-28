module Notifications
  class Notification
    # The words of each customer-facing order fact.
    module Message
      def self.for(event)
        greeting = "Hello #{event.customer_name},"
        order = "order ##{event.order_id}"

        case event
        when Orders::Events::OrderPlaced, Orders::Events::OrderPlacedV1
          [ "placed", "We have your #{order}", "#{greeting} thank you for #{order} of #{money(placed_total_cents(event))}. We will let you know when it ships." ]
        when Orders::Events::OrderShipped
          [ "shipped", "Your #{order} is on its way", "#{greeting} #{order} has shipped. Tracking code: #{event.tracking_code}." ]
        when Orders::Events::OrderDelivered
          [ "delivered", "Your #{order} was delivered", "#{greeting} #{order} was delivered. Enjoy!" ]
        when Orders::Events::OrderCancelled
          [ "cancelled", "Your #{order} was cancelled", "#{greeting} #{order} was cancelled (#{event.reason}). Nothing was charged, or it has been refunded." ]
        when Orders::Events::OrderRefunded
          [ "refunded", "Your refund for #{order}", "#{greeting} we refunded #{money(event.total.amount_cents)} for #{order}." ]
        end
      end

      # Version 1 carried an integer total; version 2 carries a Money.
      def self.placed_total_cents(event)
        event.is_a?(Orders::Events::OrderPlacedV1) ? event.total_cents : event.total.amount_cents
      end

      def self.money(cents) = format("€%.2f", cents / 100.0)
    end
  end
end
