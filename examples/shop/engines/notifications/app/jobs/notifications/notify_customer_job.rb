module Notifications
  # One subscriber for every customer-facing order fact. It subscribes to both versions of
  # OrderPlaced: the shop publishes version 2, and a version 1 delivery still queued from
  # before the upgrade is handled rather than lost.
  class NotifyCustomerJob < ApplicationJob
    subscribes_to Orders::Events::OrderPlaced, Orders::Events::OrderPlacedV1,
      Orders::Events::OrderShipped, Orders::Events::OrderDelivered,
      Orders::Events::OrderCancelled, Orders::Events::OrderRefunded

    # A notice that keeps failing is given up after three attempts: a late "your order
    # shipped" is worth less than a queue full of retries, and no order waits on it.
    retry_on StandardError, wait: 1.second, attempts: 3 do |job, error|
      Rails.logger.warn("Gave up notifying about event #{job.arguments.first.id}: #{error.message}")
    end

    def perform(event)
      kind, subject, body = message_for(event)

      Notification.insert(
        { event_id: event.id, kind: kind, order_id: event.order_id, customer_email: event.customer_email,
          subject: subject, body: body, created_at: Time.current },
        unique_by: [ :event_id, :kind ]
      )
    end

    private
      def message_for(event)
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
      def placed_total_cents(event)
        event.is_a?(Orders::Events::OrderPlacedV1) ? event.total_cents : event.total.amount_cents
      end

      def money(cents) = format("€%.2f", cents / 100.0)
  end
end
