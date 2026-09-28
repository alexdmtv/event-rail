require "application_system_test_case"

class LivePagesTest < ApplicationSystemTestCase
  test "a live page refreshes with new data and keeps its scroll position" do
    Catalog::Api.receive_stock(sku: "MUG", quantity: 100)
    30.times { checkout(items: { "MUG" => 1 }) }
    visit orders_path
    page.scroll_to(:bottom)
    scrolled = page.evaluate_script("window.scrollY")
    assert_operator scrolled, :>, 0

    order = checkout(items: { "TEA" => 1 })

    assert_selector "#order-#{order.id}", wait: 5
    assert_equal scrolled, page.evaluate_script("window.scrollY")
  end

  test "unsubmitted input survives the refreshes, and the rest of the page keeps updating" do
    visit root_path
    assert_text "Nothing published yet"
    fill_in "orders_per_minute", with: "77"
    find("h1").click # the field loses focus; its input is still unsubmitted

    checkout
    work_off_queue(due_only: true)

    assert_selector "#feed li", minimum: 2, wait: 3
    assert_field "orders_per_minute", with: "77"
  end

  test "the feed fills in while the simulator runs" do
    Simulation::Engine.load_seed
    visit root_path
    assert_text "Nothing published yet"

    click_on "Start"
    assert_selector "#simulator", text: "running"
    Simulation::Api.configure(orders_per_minute: 120, cancel_rate: 0, return_rate: 0)
    3.times { Simulation::Api.tick } # what the recurring schedule does every second
    work_off_queue(due_only: true) # what the workers do

    assert_selector "#feed li", minimum: 2, wait: 5
    assert_selector "#feed a", text: "orders.order_placed v2"
  end

  test "an order placed beyond the stock shows as cancelled without a reload" do
    Simulation::Engine.load_seed
    visit new_cart_path
    fill_in "items[MUG]", with: "99"
    click_on "Review the cart"

    click_on "Place order"
    assert_text "Being confirmed"
    work_off_queue(due_only: true) # what the workers do

    assert_text "cancelled: MUG is out of stock", wait: 5
  end

  test "placing a cart twice at once places one order" do
    Simulation::Engine.load_seed
    visit new_cart_path
    click_on "Review the cart"

    click_on "Place it twice at once"

    assert_text(/Both submissions returned order #\d+ — one order\./)
    order = Orders::Api.recent.sole

    Platform::FaultSettings.current.update!(carrier_delay_seconds: 0)
    work_off_queue
    assert_equal "delivered", Orders::Api.order(order.id).status
    assert_equal "captured", Payments::Api.payment(order.reference).state
  end
end
