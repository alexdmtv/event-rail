require "test_helper"

module Orders
  class CartsTest < ActiveSupport::TestCase
    include ShopHelpers

    setup { stock_shelves }

    def open_cart(items = { "MUG" => 2, "TEA" => 1 }) = TestSupport.open_cart(customer: CUSTOMER, items: items)

    def violations(error) = error.violations.map { |violation| [ violation.field, violation.code ] }.sort

    test "a cart holds the customer's items" do
      cart = open_cart("MUG" => "2", "TEA" => 1)

      assert_equal({ "MUG" => 2, "TEA" => 1 }, cart.items.to_h { |item| [ item.sku, item.quantity ] })
      assert_nil cart.order
    end

    test "a quantity that is not a whole number above zero is refused before a cart is opened" do
      { -2 => "greater_than", "0" => "greater_than", "1.5" => "not_an_integer", 1.5 => "not_an_integer",
        "two" => "not_a_number", nil => "not_a_number", "" => "not_a_number" }.each do |quantity, code|
        error = assert_raises(Platform::InvalidInput, quantity.inspect) { open_cart("MUG" => quantity) }
        assert_equal [ [ "items[0].quantity", code ] ], violations(error), quantity.inspect
      end

      assert_equal 0, Cart.count
    end

    test "every problem in a request is reported at once, named by the request's own fields" do
      customer = CUSTOMER.with(email: "", address: nil)

      error = assert_raises(Platform::InvalidInput) { TestSupport.open_cart(customer: customer, items: { "MUG" => "two", "SPOON" => 1, "TEA" => 1 }) }

      assert_equal [ [ "customer_email", "blank" ], [ "items[0].quantity", "not_a_number" ], [ "items[1].sku", "unknown_product" ], [ "shipping_address", "blank" ] ],
        violations(error)
      assert_equal Platform::InvalidArgument, Platform::ErrorCategory.of(error)
      assert_equal 0, Cart.count
    end

    test "an email address that is not one is refused" do
      error = assert_raises(Platform::InvalidInput) { TestSupport.open_cart(customer: CUSTOMER.with(email: "ada"), items: { "MUG" => 1 }) }

      assert_equal [ [ "customer_email", "invalid" ] ], violations(error)
    end

    test "a cart asks Catalog once about all its products" do
      assert_queries_match(/FROM "catalog_products"/, count: 1) { open_cart("MUG" => 1, "TEA" => 1) }
    end

    test "a product listed twice is refused" do
      error = assert_raises(Platform::InvalidInput) do
        Cart.open(customer_id: "c", customer_name: "Ada", customer_email: "ada@example.com", shipping_address: "London",
          items: [ { sku: "MUG", quantity: 1 }, { sku: "MUG", quantity: 2 } ])
      end

      assert_equal [ [ "items[1].sku", "taken" ] ], violations(error)
    end

    test "placing a cart records a placed order priced as the products are now, and holds nothing yet" do
      order = checkout

      assert_equal "placed", order.state
      assert_equal 2 * 1490 + 890, order.total_cents
      assert_equal 10, available("MUG"), "nothing is reserved within the request"
      assert_nil Payments::TestSupport.payment(order.reference)
      assert_enqueued_jobs 1, only: ConfirmJob
    end

    test "a cart with no items is refused when it is opened" do
      error = assert_raises(Platform::InvalidInput) { open_cart({}) }

      assert_equal [ [ "items", "blank" ] ], violations(error)
      assert_equal 0, Cart.count
    end

    test "placing a cart again returns its order, confirmed once" do
      Payments::Gateway.adapter = gateway = ScriptedGateway.new
      cart = open_cart

      first = TestSupport.place_order(cart.id)
      second = TestSupport.place_order(cart.id)
      work_off_queue
      third = TestSupport.place_order(cart.id)

      assert_equal [ first.id ] * 3, [ first, second, third ].map(&:id)
      assert_equal 1, gateway.calls[:authorize]
      assert_equal "delivered", third.status
    end

    test "two placements of one cart racing each other make one order, and the loser stages nothing" do
      cart = open_cart
      winner, loser = Cart.find(cart.id), Cart.find(cart.id)
      loser.order # the loser looked before the winner committed, and found no order

      placed = winner.place_order
      returned = loser.place_order

      assert_equal placed.id, returned.id
      assert_equal 1, Orders::Order.count
      assert_equal 1, enqueued_jobs.count { |job| job["job_class"] == ConfirmJob.name }, "the loser's staged confirmation rolled back"
      assert_equal 0, Platform::StagedJob.count
    end

    test "an order placed while the queue could not take its confirmation is confirmed without the caller retrying" do
      order = refusing_enqueue { checkout }
      assert_no_enqueued_jobs

      relay_staged_jobs
      work_off_queue

      assert_equal "delivered", order.reload.status
    end

    test "placing an order and everything it causes share one flow" do
      cart = open_cart
      published = record_publications { perform_enqueued_jobs { TestSupport.place_order(cart.id) } }

      assert_includes published.map(&:event_type), "orders.order_delivered"
      assert_equal 1, published.map(&:correlation_id).uniq.size
    end
  end
end
