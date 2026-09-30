module Orders
  class Order
    # Calling an order off. Anyone may ask -- the customer, a refused capture, a deadline -- and
    # the request is recorded at once; whether it can still happen is Fulfillment's to say, in
    # a job, because only Fulfillment knows whether the parcel has left.
    module Cancellable
      # Records the request and stages the cancellation, under the order's lock. A second
      # request, or one for an order already cancelled, changes nothing.
      def request_cancellation(reason:)
        Flow.continue(self, step: "cancel") do
          with_lock do
            next if cancellation_requested_at? || cancelled?
            raise NotCancellable, "order #{id} has shipped; request a return instead" unless cancellable?

            update!(cancellation_requested_at: Time.current, cancel_reason: reason)
            CancelJob.stage(self)
          end
        end
        self
      end

      # Stops the shipment if Fulfillment still can, and then cancels the order, announcing it
      # in the same transaction, and gives back its stock and its payment -- every run, so that
      # a run retried after the cancellation committed still gives them back.
      def cancel
        Fulfillment::Api.cancel_shipment(reference: reference)
        update_if({ state: %w[ placed confirmed ] }, state: "cancelled", cancelled_at: Time.current) do
          EventRail.stage(Events::OrderCancelled.new(**event_attributes, reason: cancel_reason))
        end
        return unless cancelled?

        release_holds
      rescue Fulfillment::AlreadyDispatched
        update_if({ cancellation_refused_at: nil }, cancellation_refused_at: Time.current)
      end
    end
  end
end
