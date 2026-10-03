module Orders
  class Order
    module Cancellable
      # Safe to repeat: a second request, or one for a cancelled order, changes nothing.
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

      # Releases the holds on every run, not only the one that cancelled, so a retry after the
      # cancellation committed still releases them.
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
