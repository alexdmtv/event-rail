module Orders
  # Checkout decides within the request, because the customer is waiting: it prices the
  # basket, reserves the stock and authorizes the card, and either accepts the order with all
  # three done or rejects it with none of them left behind. Everything after that -- the
  # announcement, capturing the payment, shipping -- runs from Orders::FollowUpJob.
  #
  # The caller's checkout key makes it safe to retry. It is the reference Orders passes to
  # Catalog and Payments, whose commands are idempotent per reference, and the key the order
  # is recorded under. A repeated checkout finds the order and, if its follow-up never got
  # scheduled, schedules it: the caller's retry is the recovery.
  class Checkout
    Error = Class.new(StandardError)

    def initialize(customer:, items:, key:)
      @customer = customer
      @items = items.to_h.transform_keys(&:to_s).transform_values { |quantity| Integer(quantity) }.reject { |_, quantity| quantity.zero? }
      @key = key.to_s
      @fingerprint = Digest::SHA256.hexdigest([ customer.id, @items.sort ].to_json)
    end

    def call
      raise Api::EmptyBasket, "a basket needs at least one item" if @items.empty?

      # The flow of this order starts here. Its message ID comes from the key, so a retried
      # checkout continues the same flow rather than starting a second one.
      EventRail.with_context(message_id: "checkout-#{@key}") do
        existing_order || schedule_follow_up(place_order)
      rescue ActiveRecord::RecordNotUnique
        existing_order # the same key checked out concurrently; the other attempt won
      end
    end

    private
      def existing_order
        order = Order.find_by(reference: @key) or return
        raise Api::ConflictingKey, "checkout key #{@key} was already used for a different basket" if order.basket_fingerprint != @fingerprint

        schedule_follow_up(order) if order.placed?
        order
      end

      # Everything up to and including the commit. Once the order is recorded it is not
      # undone: a failure after this point is recovered by the caller's retry instead.
      def place_order
        quote = quote_items
        reserve_stock
        authorize_payment(quote)
        record(quote)
      rescue Api::Error
        raise
      rescue => error
        # Anything failing before the order is recorded gives back the reservation and the
        # authorization, so a rejected checkout leaves nothing held. Both calls are
        # idempotent and safe even if the step they undo never happened.
        Catalog::Api.release(reservation_id: @key)
        Payments::Api.void(reference: @key)
        raise error
      end

      def quote_items
        Catalog::Api.quote(@items)
      rescue Catalog::Api::UnknownProduct => unknown
        raise Api::UnknownProduct, unknown.message
      end

      def reserve_stock
        Catalog::Api.reserve(reservation_id: @key, items: @items)
      rescue Catalog::Api::OutOfStock => out_of_stock
        raise Api::OutOfStock, out_of_stock.message
      end

      def authorize_payment(quote)
        Payments::Api.authorize(reference: @key, amount_cents: quote.total_cents, currency: Api::CURRENCY)
      rescue Payments::Api::Declined, Payments::Api::Unavailable => failure
        Catalog::Api.release(reservation_id: @key)
        raise(failure.is_a?(Payments::Api::Declined) ? Api::PaymentDeclined : Api::PaymentUnavailable, failure.message)
      end

      def record(quote)
        Order.transaction do
          Order.create!(
            reference: @key, basket_fingerprint: @fingerprint, state: "placed", placed_at: Time.current,
            customer_id: @customer.id, customer_name: @customer.name, customer_email: @customer.email, shipping_address: @customer.address,
            total_cents: quote.total_cents, currency: Api::CURRENCY, correlation_id: EventRail::Current.correlation_id
          ).tap do |order|
            quote.lines.each do |line|
              order.line_items.create!(sku: line.sku, name: line.name, quantity: line.quantity, unit_price_cents: line.unit_price_cents)
            end
          end
        end
      end

      # After the commit, never inside it: the queue is another database, so the two writes
      # cannot be one. If this enqueue fails, the caller sees the error, retries with the same
      # key, and existing_order schedules it. If the caller never retries, the order is
      # cancelled as abandoned after 30 minutes -- matching what the caller was told.
      def schedule_follow_up(order)
        FollowUpJob.perform_later_as("orders-follow-up-#{order.id}", order.id)
        order
      end
  end
end
