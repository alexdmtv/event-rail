# Builds a small shop for tests: two products and a customer, and a checkout helper.
module ShopHelpers
  CUSTOMER = Orders::Api::Customer.new(id: "cus_ada", name: "Ada Lovelace", email: "ada@example.com", address: "12 St James's Square, London")

  def stock_shelves
    Catalog::Api.add_product(sku: "MUG", name: "Stoneware mug", price_cents: 1490, on_hand: 10)
    Catalog::Api.add_product(sku: "TEA", name: "Green tea", price_cents: 890, on_hand: 10)
  end

  def checkout(key: "key-1", items: { "MUG" => 2, "TEA" => 1 }, customer: CUSTOMER)
    Orders::Api.checkout(customer: customer, items: items, key: key)
  end

  # Checks out and runs the order's placement, retries included, leaving what the placement
  # started -- the capture -- queued. Returns the order as placing left it: placed, or
  # rejected. (The job is named rather than referenced: it is private to Orders.)
  def place(**options)
    order = checkout(**options)
    10.times do
      break unless Orders::Api.order(order.id).state == "pending"

      perform_enqueued_jobs(only: ->(job) { job.fetch(:job).name == "Orders::PlaceOrderJob" })
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

  # Makes a module's or class's method do its work and then raise while the block runs, as
  # if the process died right after the call returned, then restores it.
  def interrupting_after(receiver, method_name, message = "interrupted after #{method_name}")
    singleton = receiver.singleton_class
    original = :"__before_interrupting_#{method_name}"
    singleton.alias_method original, method_name
    singleton.define_method(method_name) { |*arguments, **options| send(original, *arguments, **options).then { raise message } }
    yield
  ensure
    singleton.alias_method method_name, original
    singleton.remove_method original
  end

  # Makes a module's or class's method raise while the block runs, then restores it.
  def failing(receiver, method_name, message = "#{method_name} failed")
    singleton = receiver.singleton_class
    original = :"__before_failing_#{method_name}"
    singleton.alias_method original, method_name
    singleton.define_method(method_name) { |*, **| raise message }
    yield
  ensure
    singleton.alias_method method_name, original
    singleton.remove_method original
  end
end
