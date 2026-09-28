module Orders
  # Checkout records the customer's order and hands the rest to Orders::PlaceOrderJob, in one
  # transaction. It is the shop's rule for every boundary: a request records a decision and
  # stages what follows; a job does the work and retries until the shop matches the decision.
  #
  # Within the request checkout only refuses what it can tell at once -- an empty basket, a
  # quantity that is not a whole number, an unknown product -- before anything outside Orders
  # has changed, so a refusal leaves nothing to undo. Otherwise the order is recorded as
  # pending, and placing it -- reserving the stock, authorizing the card -- happens in the job.
  # The customer learns whether it was placed or rejected on the order's page, a moment later.
  #
  # The caller's checkout key makes checkout safe to repeat: there is one order per key,
  # recorded before anything is reserved or authorized. A repeat returns that order, whatever
  # its state, and a submission racing another with the same key loses at the key's unique
  # index, having touched nothing. A customer trying again after a rejection does so under a
  # new key; the console's form issues one each time it is shown.
  class Checkout
    def initialize(customer:, items:, key:)
      @customer = customer
      @items = parse(items)
      @key = key.to_s
      @fingerprint = Digest::SHA256.hexdigest([ customer.id, @items.sort ].to_json)
    end

    def call
      raise Api::EmptyBasket, "a basket needs at least one item" if @items.empty?

      # The flow of this order starts here. Its message ID comes from the key, so a repeated
      # checkout continues the same flow rather than starting a second one.
      EventRail.with_context(message_id: "checkout-#{@key}") do
        existing_order || record(quote_items)
      end
    end

    private
      def existing_order
        order = Order.find_by(checkout_key: @key) or return
        raise Api::ConflictingKey, "checkout key #{@key} was already used for a different basket" if order.basket_fingerprint != @fingerprint

        order
      end

      def quote_items
        Catalog::Api.quote(@items)
      rescue Catalog::UnknownProduct => unknown
        raise Api::UnknownProduct, unknown.message
      end

      # The order, its lines as priced now, and the job that places it commit together.
      def record(quote)
        Order.transaction do
          order = Order.create!(
            checkout_key: @key, basket_fingerprint: @fingerprint, state: "pending",
            customer_id: @customer.id, customer_name: @customer.name, customer_email: @customer.email, shipping_address: @customer.address,
            total_cents: quote.total_cents, currency: Api::CURRENCY, correlation_id: EventRail::Current.correlation_id
          )
          quote.lines.each do |line|
            order.line_items.create!(sku: line.sku, name: line.name, quantity: line.quantity, unit_price_cents: line.unit_price_cents)
          end
          PlaceOrderJob.stage_later(order.id)
          order
        end
      rescue ActiveRecord::RecordNotUnique
        existing_order or raise # another submission under the same key recorded it first
      end

      # items: { "sku" => quantity }. A quantity is a whole number, given as an Integer or as
      # the digits a form submits; a line of zero is left out, anything else is refused before
      # anything is recorded.
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
