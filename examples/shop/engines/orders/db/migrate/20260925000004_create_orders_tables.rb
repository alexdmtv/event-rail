class CreateOrdersTables < ActiveRecord::Migration[8.1]
  def change
    create_table :orders_orders do |t|
      # The checkout key the caller supplied. It is also the reference Orders gives Catalog,
      # Payments and Fulfillment, so a retried checkout reaches the same reservation and the
      # same authorization.
      t.string :reference, null: false, index: { unique: true }
      t.string :basket_fingerprint, null: false
      t.string :state, null: false
      t.string :customer_id, null: false, index: true
      t.string :customer_name, null: false
      t.string :customer_email, null: false
      t.string :shipping_address, null: false
      t.integer :total_cents, null: false
      t.string :currency, null: false
      t.string :correlation_id, null: false, index: true
      t.string :cancel_reason
      t.string :attention_reason
      t.string :tracking_code
      t.datetime :placed_at, null: false
      t.datetime :paid_at
      t.datetime :shipped_at
      t.datetime :delivered_at
      t.datetime :cancelled_at
      t.datetime :cancellation_announced_at
      t.datetime :return_requested_at
      t.datetime :refunded_at
      t.timestamps
      t.index [ :state, :placed_at ]
    end

    create_table :orders_line_items do |t|
      t.references :order, null: false, foreign_key: { to_table: :orders_orders }
      t.string :sku, null: false
      t.string :name, null: false
      t.integer :quantity, null: false
      t.integer :unit_price_cents, null: false
    end
  end
end
