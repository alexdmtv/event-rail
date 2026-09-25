require "test_helper"

module Catalog
  class ApiTest < ActiveSupport::TestCase
    setup do
      Catalog::Product.create!(sku: "MUG", name: "Mug", price_cents: 1490, on_hand: 3)
      Catalog::Product.create!(sku: "TEA", name: "Tea", price_cents: 890, on_hand: 10)
    end

    test "quotes return plain values with a total" do
      quote = Api.quote("MUG" => 2, "TEA" => 1)

      assert_equal 2 * 1490 + 890, quote.total_cents
      assert_kind_of Data, quote.lines.first
      assert_not_respond_to quote.lines.first, :save
    end

    test "a reservation holds stock for every item or for none" do
      assert_raises(Api::OutOfStock) { Api.reserve(reservation_id: "r-1", items: { "TEA" => 1, "MUG" => 4 }) }

      assert_equal 10, Api.product("TEA").available
      assert_equal 3, Api.product("MUG").available
    end

    test "repeating a reservation holds nothing more" do
      2.times { Api.reserve(reservation_id: "r-1", items: { "MUG" => 2 }) }

      assert_equal 1, Api.product("MUG").available
    end

    test "releasing twice gives the stock back once" do
      Api.reserve(reservation_id: "r-1", items: { "MUG" => 2 })
      2.times { Api.release(reservation_id: "r-1") }

      assert_equal 3, Api.product("MUG").available
    end

    test "shipping and restocking move stock once each" do
      Api.reserve(reservation_id: "r-1", items: { "MUG" => 2 })
      2.times { Api.ship(reservation_id: "r-1") }
      assert_equal 1, Catalog::Product.find_by!(sku: "MUG").on_hand

      2.times { Api.restock(reservation_id: "r-1") }
      assert_equal 3, Catalog::Product.find_by!(sku: "MUG").on_hand
    end

    test "an unknown product is refused" do
      assert_raises(Api::UnknownProduct) { Api.quote("NOPE" => 1) }
    end
  end
end
