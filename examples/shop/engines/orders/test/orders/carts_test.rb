require "test_helper"
require_relative "../support/order_records"

module Orders
  class CartsTest < ActiveSupport::TestCase
    include ShopHelpers
    include OrderRecords

    setup { stock_shelves }

    def open_cart(items = { "MUG" => 2, "TEA" => 1 }) = Api.open_cart(customer: CUSTOMER, items: items)

    test "a cart holds the customer's items, and a line of zero is left out" do
      cart = open_cart("MUG" => "2", "TEA" => "0")

      assert_equal({ "MUG" => 2 }, cart.items)
      assert_nil cart.order_id
    end

    test "a quantity that is not a whole number above zero is refused before a cart is opened" do
      [ -2, "-2", "1.5", 1.5, "two", nil, "" ].each do |quantity|
        assert_raises(InvalidQuantity, quantity.inspect) { open_cart("MUG" => quantity) }
      end

      assert_equal 0, Cart.count
    end

    test "a product the shop does not sell is refused as the customer's mistake" do
      error = assert_raises(UnknownProduct) { open_cart("SPOON" => 1) }

      assert_equal Platform::InvalidArgument, Platform::ErrorCategory.of(error)
    end

    test "placing a cart records a placed order priced as the products are now, and holds nothing yet" do
      order = checkout

      assert_equal "placed", order.state
      assert_equal 2 * 1490 + 890, order.total_cents
      assert_equal 10, available("MUG"), "nothing is reserved within the request"
      assert_nil Payments::Api.payment(order.reference)
      assert_enqueued_jobs 1, only: ConfirmJob
    end

    test "an empty cart cannot be ordered" do
      cart = open_cart({})

      assert_raises(EmptyCart) { Api.place_order(cart.id) }
      assert_equal 0, Orders::Order.count
      assert_no_enqueued_jobs
    end

    test "placing a cart again returns its order, confirmed once" do
      Payments::Gateway.adapter = gateway = ScriptedGateway.new
      cart = open_cart

      first = Api.place_order(cart.id)
      second = Api.place_order(cart.id)
      work_off_queue
      third = Api.place_order(cart.id)

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

    test "an ordered cart takes no more items" do
      cart = open_cart
      Api.place_order(cart.id)

      assert_raises(CartAlreadyOrdered) { Cart.find(cart.id).add("TEA", Quantity.parse(1)) }
    end

    test "an order placed while the queue could not take its confirmation is confirmed without the caller retrying" do
      order = refusing_enqueue { checkout }
      assert_no_enqueued_jobs

      relay_staged_jobs
      work_off_queue

      assert_equal "delivered", order_record(order).status
    end

    test "the order's flow is correlated by its cart, and placing the cart again continues it" do
      cart = open_cart
      order = nil
      published = record_publications { perform_enqueued_jobs { order = Api.place_order(cart.id) } }

      assert_equal "cart-#{cart.id}", order.correlation_id
      assert_includes published.map(&:event_type), "orders.order_delivered"
      assert published.all? { |publication| publication.correlation_id == order.correlation_id }
      assert_equal order.id, Api.order_for_correlation(order.correlation_id).id
      assert_nil Api.order_for_correlation("unknown")
    end
  end
end
