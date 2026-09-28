# Builds a small shop for tests: two products and a customer, and a checkout helper.
module ShopHelpers
  CUSTOMER = Orders::Api::Customer.new(id: "cus_ada", name: "Ada Lovelace", email: "ada@example.com", address: "12 St James's Square, London")

  def stock_shelves
    Catalog::Api.add_product(sku: "MUG", name: "Stoneware mug", price_cents: 1490, on_hand: 10)
    Catalog::Api.add_product(sku: "TEA", name: "Green tea", price_cents: 890, on_hand: 10)
  end

  # Opens a cart with the items and places it; returns the order, placed.
  def checkout(items: { "MUG" => 2, "TEA" => 1 }, customer: CUSTOMER)
    Orders::Api.place_order(Orders::Api.open_cart(customer: customer, items: items).id)
  end

  # Checks out and runs the order's confirmation -- and, when confirming it cancelled it, the
  # cancellation -- retries included, leaving what confirming started (the capture) queued.
  # Returns the order as that left it: confirmed, or cancelled. (The jobs are named rather than
  # referenced: they are private to Orders.)
  def place(**options)
    order = checkout(**options)
    confirming = ->(job) { %w[ Orders::ConfirmJob Orders::CancelJob ].include?(job.fetch(:job).name) }
    10.times do
      break if enqueued_jobs.none? { |job| %w[ Orders::ConfirmJob Orders::CancelJob ].include?(job["job_class"]) }

      perform_enqueued_jobs(only: confirming)
    end
    Orders::Api.order(order.id)
  end

  def available(sku) = Catalog::Api.product(sku).available
  def on_hand(sku) = Catalog::Api.product(sku).on_hand

  # Runs the jobs already due, and the due jobs those enqueue, until none is left; later
  # carrier steps stay queued.
  def perform_due_jobs
    perform_enqueued_jobs(at: Time.current) while enqueued_jobs.any? { |job| job[:at].nil? || job[:at] <= Time.current.to_f }
  end

  # Makes the carrier slow enough that its steps stay queued unless a test performs them.
  def slow_carrier = Platform::FaultSettings.current.update!(carrier_delay_seconds: 3600)
end
