require "application_system_test_case"

class LivePagesTest < ApplicationSystemTestCase
  test "a live page refreshes with new data and keeps its scroll position" do
    Catalog::Api.receive_stock(sku: "MUG", quantity: 100)
    30.times { |index| checkout(key: "key-#{index}", items: { "MUG" => 1 }) }
    visit orders_path
    page.scroll_to(:bottom)
    scrolled = page.evaluate_script("window.scrollY")
    assert_operator scrolled, :>, 0

    order = checkout(key: "the-new-one", items: { "TEA" => 1 })

    assert_selector "#order-#{order.id}", wait: 5
    assert_equal scrolled, page.evaluate_script("window.scrollY")
  end

  test "a refresh never discards what the developer is typing" do
    visit root_path
    fill_in "orders_per_minute", with: "77"
    find("h1").click # the field loses focus; its input is still unsaved
    checkout
    sleep 3 # longer than the refresh interval: an absence can only be checked by waiting

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

  test "submitting the checkout form twice at once places one order" do
    Simulation::Engine.load_seed
    visit new_order_path

    click_on "Submit it twice at once"

    assert_text(/Both submissions returned order #\d+ — one order\./)
    assert_equal 1, Orders::Api.recent.size
  end
end
