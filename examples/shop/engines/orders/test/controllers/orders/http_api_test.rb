require "test_helper"

module Orders
  class HttpApiTest < ActionDispatch::IntegrationTest
    include ShopHelpers

    CUSTOMER_PARAMS = { id: "cus_ada", name: "Ada Lovelace", email: "ada@example.com", address: "12 St James's Square, London" }.freeze

    setup { stock_shelves }

    def open_cart(items = { "MUG" => 2, "TEA" => 1 })
      post "/carts", params: { customer: CUSTOMER_PARAMS, items: items }, as: :json
      response.parsed_body
    end

    def place(cart) = post("/carts/#{cart["id"]}/order", as: :json).then { response.parsed_body }

    test "a cart is opened and placed, and the order read back" do
      cart = open_cart
      assert_response :created
      assert_equal [ { "sku" => "MUG", "quantity" => 2 }, { "sku" => "TEA", "quantity" => 1 } ], cart["items"].sort_by { |item| item["sku"] }

      order = place(cart)
      assert_response :created
      assert_equal "placed", order["status"]
      assert_equal({ "cents" => 2 * 1490 + 890, "currency" => "EUR" }, order["total"])

      perform_enqueued_jobs(only: ConfirmJob)
      get "/orders/#{order["id"]}", as: :json
      assert_response :ok
      assert_equal "confirmed", response.parsed_body["status"]
    end

    test "placing a cart again answers with the same order" do
      cart = open_cart

      first, second = 2.times.map { place(cart) }

      assert_equal first["id"], second["id"]
      assert_equal 1, Order.count
    end

    test "a refused cart is answered with every problem, each pointing at its field" do
      post "/carts", params: { customer: CUSTOMER_PARAMS.except(:email), items: { "MUG" => "two", "SPOON" => 1 } }, as: :json

      assert_response :unprocessable_content
      assert_equal "application/problem+json", response.media_type
      problem = response.parsed_body
      assert_equal [ 422, "invalid_input" ], problem.values_at("status", "code")
      assert_equal [ [ "/customer/email", "blank" ], [ "/items/MUG", "not_a_quantity" ], [ "/items/SPOON", "unknown_product" ] ],
        problem["errors"].map { |error| error.values_at("pointer", "code") }
      assert_equal "can't be blank", problem["errors"].first["detail"]
      assert_equal 0, Cart.count
    end

    test "a cart with no customer is refused, pointing at the missing field" do
      post "/carts", params: { items: { "MUG" => 1 } }, as: :json

      assert_response :unprocessable_content
      assert_equal [ [ "/customer", "missing" ] ], response.parsed_body["errors"].map { |error| error.values_at("pointer", "code") }
    end

    test "a cancellation is accepted, and carried out a moment later" do
      order = place(open_cart)

      post "/orders/#{order["id"]}/cancellation", as: :json
      assert_response :accepted
      assert response.parsed_body["cancellation_requested_at"]

      perform_enqueued_jobs
      get "/orders/#{order["id"]}", as: :json
      assert_equal "cancelled", response.parsed_body["status"]
    end

    test "a return of an order that was not delivered is refused" do
      order = place(open_cart)

      post "/orders/#{order["id"]}/return", as: :json

      assert_response :conflict
      problem = response.parsed_body
      assert_equal [ 409, "Conflict", "not_returnable" ], problem.values_at("status", "title", "code")
      assert problem["detail"]
      assert_not problem.key?("errors")
    end

    test "a delivered order's return is accepted" do
      instant_carrier
      order = perform_enqueued_jobs { place(open_cart) }

      post "/orders/#{order["id"]}/return", as: :json

      assert_response :accepted
      assert_equal "returning", response.parsed_body["status"]
    end

    test "an order that does not exist is not found" do
      get "/orders/0", as: :json

      assert_response :not_found
      assert_equal [ 404, "record_not_found" ], response.parsed_body.values_at("status", "code")
    end

    test "a path no route matches is answered as problem details too, as in production" do
      # Tests, like development, answer with Rails' debugging details; production does not.
      detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
      Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
      get "/nowhere", as: :json

      assert_response :not_found
      assert_equal "application/problem+json", response.media_type
      assert_equal({ "title" => "Not Found", "status" => 404 }, response.parsed_body)
    ensure
      Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = detailed
    end
  end
end
