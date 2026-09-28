require "test_helper"

class ConsoleTest < ActionDispatch::IntegrationTest
  include ShopHelpers

  setup { stock_shelves }

  test "the console shows the simulator, the fault controls and the latest publications" do
    order = checkout
    work_off_queue(due_only: true)

    get root_path

    assert_response :success
    assert_select "#simulator", text: /stopped/
    assert_select "#faults input[name=temporary_failure_rate]"
    assert_select "#feed li", minimum: 2
    assert_select "#feed a[href=?]", flow_path(order.correlation_id), text: "orders.order_placed v2"
  end

  test "the simulator starts, stops and takes a new rate" do
    patch simulation_path, params: { command: "start" }
    assert Simulation::Api.state.running
    assert_redirected_to root_path

    patch simulation_path, params: { orders_per_minute: 45, cancel_rate: 20, return_rate: 5 }
    state = Simulation::Api.state
    assert_equal [ 45, 0.2, 0.05 ], [ state.orders_per_minute, state.cancel_rate, state.return_rate ]

    patch simulation_path, params: { command: "stop" }
    assert_not Simulation::Api.state.running
  end

  test "faults are set as percentages and take effect at once" do
    patch faults_path, params: { authorization_decline_rate: 100, capture_refusal_rate: 0, refund_refusal_rate: 0, temporary_failure_rate: 0, carrier_delay_seconds: 2 }

    assert_redirected_to root_path
    order = place
    assert_equal "cancelled", order.state
    assert_match(/\Apayment declined/, order.cancel_reason)
  end

  test "a chosen job fails its next runs" do
    patch faults_path, params: { job_class: "Loyalty::AwardPointsJob", count: 2 }

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".forced", text: /Loyalty::AwardPointsJob\s+fails 2 more runs/
  end

  test "an unknown job cannot be broken" do
    patch faults_path, params: { job_class: "Kernel", count: 2 }

    assert_response :bad_request
  end

  test "the orders page shows each module's view of an order as it moves on" do
    slow_carrier
    order = checkout
    assert_columns order, "placed", nil, nil, "—"

    perform_enqueued_jobs(only: ->(job) { job.fetch(:job).name == "Orders::ConfirmJob" })
    assert_columns order, "confirmed", "authorized", nil, "—"

    work_off_queue(due_only: true)
    assert_columns order, "paid", "captured", "requested", "—"

    next_carrier_step
    assert_columns order, "shipped", "captured", "dispatched", "—"

    next_carrier_step
    assert_columns order, "delivered", "captured", "delivered", (order.total_cents / 100).to_s
  end

  test "the flow page shows a retried capture with its errors" do
    Payments::Gateway.adapter = ScriptedGateway.new(capture: [ :timeout, :timeout ])
    order = checkout
    work_off_queue

    get order_path(order.id)

    assert_response :success
    capture = css_select("li.step.job").find { |step| step.at_css("> .step-line code")&.text == "Payments::CaptureJob" }
    assert_equal %w[ failed failed succeeded ], capture.css("> .step-line .attempt").map { |attempt| attempt["class"].split.last }
    errors = capture.css("> .errors li").map(&:text)
    assert_equal 2, errors.size
    assert errors.all? { |error| error.include?("Payments::Gateway::TemporaryFailure") && error.include?("timed out by the script") }
  end

  test "an order not yet dispatched can be cancelled from its flow page" do
    slow_carrier
    order = checkout
    work_off_queue(due_only: true)

    get order_path(order.id)
    assert_select "form[action=?]", cancellation_order_path(order.id)

    post cancellation_order_path(order.id)
    assert_redirected_to order_path(order.id)
    follow_redirect!
    assert_select "p", text: /Cancellation requested/

    work_off_queue(due_only: true)
    get order_path(order.id)
    assert_select "h1 .pill", "cancelled"
    assert_select ".step.event", text: /orders.order_cancelled/
    assert_select "form[action=?]", cancellation_order_path(order.id), count: 0
  end

  test "a shipped order cannot be cancelled" do
    slow_carrier
    order = checkout
    work_off_queue(due_only: true)
    next_carrier_step

    post cancellation_order_path(order.id)

    assert_redirected_to order_path(order.id)
    assert_match(/has shipped; request a return instead/, flash[:alert])
  end

  test "a delivered order can be returned from its flow page" do
    Platform::FaultSettings.current.update!(carrier_delay_seconds: 0)
    order = checkout
    work_off_queue

    get order_path(order.id)
    assert_select "form[action=?]", return_order_path(order.id)

    post return_order_path(order.id)
    work_off_queue

    assert_equal "refunded", Orders::Api.order(order.id).status
    follow_redirect!
    assert_select ".step.event", text: /orders.order_refunded/
    assert_select "form[action=?]", return_order_path(order.id), count: 0
  end

  test "an order in the feed links to its flow page" do
    order = checkout

    get flow_path(order.correlation_id)

    assert_redirected_to order_path(order.id)
  end

  test "an order's page shows its cart and its reference" do
    order = checkout

    get order_path(order.id)

    assert_select "a[href=?]", cart_path(order.cart_id)
    assert_select "code", text: order.reference
  end

  test "a flow that belongs to no order goes back to the console" do
    get flow_path("unknown")

    assert_redirected_to root_path
  end

  test "the new cart form lists the customers and the products" do
    Simulation::Engine.load_seed

    get new_cart_path

    assert_response :success
    assert_select "select[name=customer_id] option", 12
    assert_select "input[name='items[MUG]']"
  end

  test "a cart is filled, reviewed and placed, and placing it twice returns the same order" do
    Simulation::Engine.load_seed
    post carts_path, params: { customer_id: "cus_1", items: { "MUG" => 1, "TEA" => 0 } }
    cart_id = response.location[%r{/carts/(\d+)}, 1]
    follow_redirect!
    assert_select "[data-action='double-submit#submit']"

    post order_cart_path(cart_id, format: :json)
    first = response.parsed_body
    post order_cart_path(cart_id, format: :json)
    second = response.parsed_body

    assert_equal first, second
    assert_equal 1, Orders::Api.recent.size
  end

  test "an order cancelled while it was being confirmed says why on its page" do
    Simulation::Engine.load_seed
    post carts_path, params: { customer_id: "cus_1", items: { "MUG" => 99 } }
    post order_cart_path(response.location[%r{/carts/(\d+)}, 1])
    order = Orders::Api.recent.sole
    assert_redirected_to order_path(order.id)
    follow_redirect!
    assert_select "p", text: /Being confirmed/

    work_off_queue
    get order_path(order.id)

    assert_select "h1 .pill", "cancelled"
    assert_select "p", text: /cancelled: MUG is out of stock/
  end

  test "an empty cart cannot be placed, and says why" do
    Simulation::Engine.load_seed
    post carts_path, params: { customer_id: "cus_1", items: { "MUG" => 0 } }
    cart_id = response.location[%r{/carts/(\d+)}, 1]

    post order_cart_path(cart_id)

    assert_redirected_to cart_path(cart_id)
    assert_match(/Order refused: a cart needs at least one item/, flash[:alert])
  end

  test "a quantity that is not a whole number is refused before a cart is opened" do
    Simulation::Engine.load_seed

    [ "-2", "1.5" ].each do |quantity|
      post carts_path, params: { customer_id: "cus_1", items: { "MUG" => quantity } }
      assert_redirected_to new_cart_path
      assert_match(/not a quantity/, flash[:alert])
    end

    assert_empty Orders::Api.recent
    assert_equal 10, available("MUG")
  end

  test "the architecture page draws the declared dependencies and the observed event map" do
    Platform::FaultSettings.current.update!(carrier_delay_seconds: 0)
    checkout
    work_off_queue

    get architecture_path

    assert_response :success
    drawn = css_select("line.edge").map { |line| line["data-edge"] }.sort
    assert_equal declared_edges.reject { |edge| edge.end_with?("->Platform") }, drawn
    assert_select "g.node text", text: "Platform"
    assert_select "tr", text: /orders.order_delivered/ do
      assert_select ".subscriber", text: /AwardPointsJob/
    end
  end

  private
    # The slow carrier's next scheduled step comes due. Time travel drops the microseconds, so
    # an exact hour would land just before it.
    def next_carrier_step
      travel 61.minutes
      work_off_queue(due_only: true)
    end

    def assert_columns(order, *columns)
      get orders_path
      assert_response :success
      cells = css_select("#order-#{order.id} td")[3, 4].map { |cell| cell.text.strip.presence }
      assert_equal columns.map { |column| column || "—" }, cells
    end

    # Module to module, as the package.yml files declare it.
    def declared_edges
      packages = {}
      Dir[Rails.root.join("engines/*/package.yml")].each { |path| packages[File.basename(File.dirname(path)).camelize] = path }
      packages.flat_map do |name, path|
        YAML.load_file(path).fetch("dependencies", []).map { |dependency| dependency.split("/")[1].camelize }.uniq
          .reject { |target| target == name }.map { |target| "#{name}->#{target}" }
      end.sort
    end
end
