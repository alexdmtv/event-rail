class CreateOrdersTables < ActiveRecord::Migration[8.1]
  def change
    # A customer's list of intended purchases. It becomes one order: the order holds the cart's
    # ID under a unique index, and a cart is ordered when its order exists.
    create_table :orders_carts do |t|
      t.string :customer_id, null: false, index: true
      t.string :customer_name, null: false
      t.string :customer_email, null: false
      t.string :shipping_address, null: false
      t.timestamps
    end

    create_table :orders_cart_items do |t|
      t.references :cart, null: false, foreign_key: { to_table: :orders_carts }
      t.string :sku, null: false
      t.integer :quantity, null: false
      t.index [ :cart_id, :sku ], unique: true
      t.check_constraint "quantity > 0", name: "orders_cart_items_quantity_positive"
    end

    create_table :orders_orders do |t|
      t.references :cart, null: false, index: { unique: true }, foreign_key: { to_table: :orders_carts }
      # The order's own reference, generated when it is placed: what Orders gives Catalog,
      # Payments and Fulfillment, and what their events name the order by.
      t.string :reference, null: false, index: { unique: true }
      # placed, confirmed or cancelled. What happened after confirming is recorded as facts.
      t.string :state, null: false
      t.string :customer_id, null: false, index: true
      t.string :customer_name, null: false
      t.string :customer_email, null: false
      t.string :shipping_address, null: false
      t.integer :total_cents, null: false
      t.string :currency, null: false
      t.string :correlation_id, null: false, index: true
      t.datetime :confirmed_at
      t.datetime :paid_at
      t.datetime :shipped_at
      t.string :tracking_code
      t.datetime :delivered_at
      t.datetime :cancellation_requested_at
      t.string :cancel_reason
      t.datetime :cancellation_refused_at
      t.datetime :cancelled_at
      t.string :attention_reason
      t.timestamps
      t.index [ :state, :created_at ]
      t.index [ :state, :confirmed_at ]
    end

    create_table :orders_line_items do |t|
      t.references :order, null: false, foreign_key: { to_table: :orders_orders }
      t.string :sku, null: false
      t.string :name, null: false
      t.integer :quantity, null: false
      t.integer :unit_price_cents, null: false
    end

    # A delivered order coming back, whole.
    create_table :orders_returns do |t|
      t.references :order, null: false, index: { unique: true }, foreign_key: { to_table: :orders_orders }
      # requested, received, refunded or refund_failed.
      t.string :state, null: false
      t.datetime :received_at
      t.datetime :refunded_at
      t.string :failure_reason
      t.timestamps
    end
  end
end
