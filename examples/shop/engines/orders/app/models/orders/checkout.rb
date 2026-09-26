module Orders
  # Checkout decides within the request, because the customer is waiting: it prices the
  # basket, reserves the stock and authorizes the card, and either accepts the order with all
  # three done or rejects it with none of them left behind. Everything after that -- the
  # announcement, capturing the payment, shipping -- runs from Orders::FollowUpJob, which is
  # staged in the same transaction as the order: the two commit together, so an order that
  # was accepted always proceeds, whether or not the caller hears the answer.
  #
  # The caller's checkout key names the customer's intent, and makes checkout safe to retry:
  # there is at most one order per key. Each run under the key is an attempt with a reference
  # of its own, `<key>/<attempt id>`, which is what Orders gives Catalog and Payments. An
  # attempt therefore only ever gives back what it took itself -- never the reservation or
  # authorization of an attempt that was rejected before it, or that won a race against it.
  #
  # A repeated checkout finds the order and returns it, running nothing again. One that finds
  # no order is a new attempt, because every earlier one was rejected.
  class Checkout
    # Another attempt under the same key committed its order first.
    class AnotherAttemptWon < StandardError; end

    def initialize(customer:, items:, key:)
      @customer = customer
      @items = parse(items)
      @key = key.to_s
      @reference = "#{@key}/#{SecureRandom.hex(6)}"
      @fingerprint = Digest::SHA256.hexdigest([ customer.id, @items.sort ].to_json)
    end

    def call
      raise Api::EmptyBasket, "a basket needs at least one item" if @items.empty?

      # The flow of this order starts here. Its message ID comes from the key, so a retried
      # checkout continues the same flow rather than starting a second one.
      EventRail.with_context(message_id: "checkout-#{@key}") do
        existing_order || attempt
      end
    end

    private
      def existing_order
        order = Order.find_by(checkout_key: @key) or return
        raise Api::ConflictingKey, "checkout key #{@key} was already used for a different basket" if order.basket_fingerprint != @fingerprint

        order
      end

      def attempt
        place_order
      rescue AnotherAttemptWon
        existing_order
      end

      # Everything up to and including the commit of the order with its follow-up.
      def place_order
        quote = quote_items
        reserve_stock
        authorize_payment(quote)
        record(quote)
      rescue => error
        give_back
        raise AnotherAttemptWon if error.is_a?(ActiveRecord::RecordNotUnique) && Order.exists?(checkout_key: @key)
        raise
      end

      def quote_items
        Catalog::Api.quote(@items)
      rescue Catalog::Api::UnknownProduct => unknown
        raise Api::UnknownProduct, unknown.message
      end

      def reserve_stock
        Catalog::Api.reserve(reservation_id: @reference, items: @items)
        @reserved = true
      rescue Catalog::Api::OutOfStock => out_of_stock
        raise Api::OutOfStock, out_of_stock.message
      end

      def authorize_payment(quote)
        Payments::Api.authorize(reference: @reference, amount_cents: quote.total_cents, currency: Api::CURRENCY)
        @authorized = true
      rescue Payments::Api::Declined => declined
        raise Api::PaymentDeclined, declined.message
      rescue Payments::Api::Unavailable => unavailable
        raise Api::PaymentUnavailable, unavailable.message
      end

      def record(quote)
        Order.transaction do
          Order.create!(
            checkout_key: @key, reference: @reference, basket_fingerprint: @fingerprint, state: "placed", placed_at: Time.current,
            customer_id: @customer.id, customer_name: @customer.name, customer_email: @customer.email, shipping_address: @customer.address,
            total_cents: quote.total_cents, currency: Api::CURRENCY, correlation_id: EventRail::Current.correlation_id
          ).tap do |order|
            quote.lines.each do |line|
              order.line_items.create!(sku: line.sku, name: line.name, quantity: line.quantity, unit_price_cents: line.unit_price_cents)
            end
            FollowUpJob.stage_later_as("orders-follow-up-#{order.id}", order.id)
          end
        end
      end

      # A rejected attempt gives back what it took, by its own reference. The void is an
      # asynchronous command and may land after the caller has heard the rejection; a retry
      # cannot be affected, because it runs under a reference of its own.
      def give_back
        Catalog::Api.release(reservation_id: @reference) if @reserved
        Payments::Api.void(reference: @reference) if @authorized
      end

      # items: { "sku" => quantity }. A quantity is a whole number, given as an Integer or as
      # the digits a form submits; a line of zero is left out, anything else is refused before
      # a single item is reserved.
      def parse(items)
        items.to_h.to_h do |sku, quantity|
          [ sku.to_s, whole_number(quantity) || raise(Api::InvalidQuantity, "#{sku}: #{quantity.inspect} is not a quantity") ]
        end.reject { |_, quantity| quantity.zero? }
      end

      def whole_number(value)
        case value
        when Integer then value unless value.negative?
        when String then Integer(value, 10) if value.strip.match?(/\A\d+\z/)
        end
      end
  end
end
