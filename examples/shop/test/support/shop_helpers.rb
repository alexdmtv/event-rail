module ShopHelpers
  CUSTOMER = Orders::TestSupport::Customer.new(id: "cus_ada", name: "Ada Lovelace", email: "ada@example.com", address: "12 St James's Square, London")

  def stock_shelves
    Catalog::TestSupport.add_product(sku: "MUG", name: "Stoneware mug", price_cents: 1490, on_hand: 10)
    Catalog::TestSupport.add_product(sku: "TEA", name: "Green tea", price_cents: 890, on_hand: 10)
  end

  def checkout(items: { "MUG" => 2, "TEA" => 1 }, customer: CUSTOMER)
    Orders::TestSupport.place_order(Orders::TestSupport.open_cart(customer: customer, items: items).id)
  end

  # Runs confirmation, and any cancellation it caused, leaving the capture queued; returns the
  # order confirmed or cancelled. The jobs are named, not referenced: they are private to Orders.
  def place(**options)
    order = checkout(**options)
    confirming = ->(job) { %w[ Orders::ConfirmJob Orders::CancelJob ].include?(job.fetch(:job).name) }
    10.times do
      break if enqueued_jobs.none? { |job| %w[ Orders::ConfirmJob Orders::CancelJob ].include?(job["job_class"]) }

      perform_enqueued_jobs(only: confirming)
    end
    Orders::TestSupport.order(order.id)
  end

  def available(sku) = Catalog::TestSupport.product(sku).available
  def on_hand(sku) = Catalog::TestSupport.product(sku).on_hand

  # Repeats until no due job is left, since due jobs enqueue more; later jobs stay queued.
  def perform_due_jobs
    perform_enqueued_jobs(at: Time.current) while enqueued_jobs.any? { |job| job[:at].nil? || job[:at] <= Time.current.to_f }
  end

  def slow_carrier = Fulfillment::Carrier.adapter = Fulfillment::Carrier::Fake.new(delay: 1.hour)

  def instant_carrier = Fulfillment::Carrier.adapter = Fulfillment::Carrier::Fake.new(delay: 0)
end
