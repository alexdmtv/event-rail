require "test_helper"

module Catalog
  class ApiTest < ActiveSupport::TestCase
    setup do
      Catalog::Product.create!(sku: "MUG", name: "Mug", price_cents: 1490, on_hand: 3)
      Catalog::Product.create!(sku: "TEA", name: "Tea", price_cents: 890, on_hand: 10)
    end

    def available(sku) = Product.find_by_sku!(sku).available

    test "products are looked up for many SKUs in one query, leaving out what the shop does not sell" do
      assert_queries_count(1) do
        assert_equal %w[ MUG TEA ], Api.products(%w[ MUG SPOON TEA ]).map(&:sku).sort
      end
    end

    test "a quote prices every item in one query" do
      assert_queries_count(1) { Api.quote("MUG" => 2, "TEA" => 1) }
    end

    test "quotes return plain values with a total" do
      quote = Api.quote("MUG" => 2, "TEA" => 1)

      assert_equal [ 2 * 1490 + 890, "EUR" ], [ quote.total_cents, quote.currency ]
      assert_kind_of Data, quote.lines.first
      assert_not_respond_to quote.lines.first, :save
    end

    test "a reservation refuses a quantity that is not a positive integer" do
      [ -2, 0, "1", 1.5 ].each do |quantity|
        assert_raises(InvalidQuantity, quantity.inspect) { Api.reserve(reference: "r-#{quantity}", items: { "TEA" => quantity }) }
      end

      assert_equal 10, available("TEA")
    end

    test "a reservation holds stock for every item or for none" do
      assert_raises(OutOfStock) { Api.reserve(reference: "r-1", items: { "TEA" => 1, "MUG" => 4 }) }

      assert_equal 10, available("TEA")
      assert_equal 3, available("MUG")
    end

    test "repeating a reservation holds nothing more" do
      2.times { Api.reserve(reference: "r-1", items: { "MUG" => 2 }) }

      assert_equal 1, available("MUG")
    end

    test "releasing twice gives the stock back once" do
      Api.reserve(reference: "r-1", items: { "MUG" => 2 })
      2.times { Api.release(reference: "r-1") }

      assert_equal 3, available("MUG")
    end

    test "shipping and restocking move stock once each" do
      Api.reserve(reference: "r-1", items: { "MUG" => 2 })
      2.times { Api.ship(reference: "r-1") }
      assert_equal 1, Catalog::Product.find_by!(sku: "MUG").on_hand

      2.times { Api.restock(reference: "r-1") }
      assert_equal 3, Catalog::Product.find_by!(sku: "MUG").on_hand
    end

    test "a reference holds once, whatever the items of a later call" do
      Api.reserve(reference: "r-1", items: { "MUG" => 2 })
      Api.reserve(reference: "r-1", items: { "TEA" => 5 })
      Api.reserve(reference: "r-1", items: { "TEA" => 0 })

      assert_equal [ 1, 10 ], [ available("MUG"), available("TEA") ]
    end

    test "holding nothing is a mistake, not a reservation" do
      assert_raises(ArgumentError) { Api.reserve(reference: "r-1", items: {}) }
      Api.reserve(reference: "r-1", items: { "MUG" => 1 })

      assert_equal 2, available("MUG")
    end

    test "a hold takes its products in ID order, the order shipping and restocking take them in" do
      assert_queries_match(/FROM "catalog_products" WHERE .* ORDER BY "catalog_products"."id"/) do
        Api.reserve(reference: "r-1", items: { "TEA" => 1, "MUG" => 1 })
      end
    end

    test "a restock before its shipment raises to be retried, so the returned stock is not lost" do
      Api.reserve(reference: "r-1", items: { "MUG" => 2 })

      assert_raises(NotYetShipped) { Api.restock(reference: "r-1") }
      Api.ship(reference: "r-1")
      Api.restock(reference: "r-1")
      assert_equal 3, Catalog::Product.find_by!(sku: "MUG").on_hand
    end

    test "a released reservation cannot ship" do
      Api.reserve(reference: "r-1", items: { "MUG" => 2 })
      Api.release(reference: "r-1")

      assert_raises(AlreadyReleased) { Api.ship(reference: "r-1") }
      assert_equal 3, Catalog::Product.find_by!(sku: "MUG").on_hand
    end

    test "release, ship and restock do nothing for a reference that holds nothing" do
      assert Api.release(reference: "nobody")
      assert Api.ship(reference: "nobody")
      assert Api.restock(reference: "nobody")
    end

    test "an unknown product is refused" do
      assert_raises(UnknownProduct) { Api.quote("NOPE" => 1) }
    end

    test "the database refuses stock below zero, whatever skips the model" do
      assert_raises(ActiveRecord::StatementInvalid) { Catalog::Product.find_by_sku!("MUG").update_column(:on_hand, -1) }
    end
  end
end
