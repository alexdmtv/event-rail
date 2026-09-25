# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_25_000007) do
  create_table "catalog_products", force: :cascade do |t|
    t.string "sku", null: false
    t.string "name", null: false
    t.integer "price_cents", null: false
    t.integer "on_hand", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sku"], name: "index_catalog_products_on_sku", unique: true
  end

  create_table "catalog_reservations", force: :cascade do |t|
    t.string "reservation_id", null: false
    t.integer "product_id", null: false
    t.integer "quantity", null: false
    t.string "state", default: "held", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_catalog_reservations_on_product_id"
    t.index ["reservation_id", "product_id"], name: "index_catalog_reservations_on_reservation_id_and_product_id", unique: true
  end

  create_table "fulfillment_returns", force: :cascade do |t|
    t.string "reference", null: false
    t.string "state", default: "expected", null: false
    t.datetime "received_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["reference"], name: "index_fulfillment_returns_on_reference", unique: true
  end

  create_table "fulfillment_shipments", force: :cascade do |t|
    t.string "reference", null: false
    t.string "recipient_name", null: false
    t.string "address", null: false
    t.json "items", default: {}, null: false
    t.string "state", default: "requested", null: false
    t.string "tracking_code"
    t.datetime "dispatched_at"
    t.datetime "delivered_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["reference"], name: "index_fulfillment_shipments_on_reference", unique: true
  end

  create_table "loyalty_entries", force: :cascade do |t|
    t.string "customer_id", null: false
    t.string "order_id", null: false
    t.string "kind", null: false
    t.integer "points", null: false
    t.string "event_id", null: false
    t.datetime "created_at", null: false
    t.index ["customer_id"], name: "index_loyalty_entries_on_customer_id"
    t.index ["order_id", "kind"], name: "index_loyalty_entries_on_order_id_and_kind", unique: true
  end

  create_table "notifications_notifications", force: :cascade do |t|
    t.string "event_id", null: false
    t.string "kind", null: false
    t.string "order_id", null: false
    t.string "customer_email", null: false
    t.string "subject", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.index ["event_id", "kind"], name: "index_notifications_notifications_on_event_id_and_kind", unique: true
    t.index ["order_id"], name: "index_notifications_notifications_on_order_id"
  end

  create_table "observability_attempts", force: :cascade do |t|
    t.string "job_id", null: false
    t.string "job_class", null: false
    t.integer "number", null: false
    t.string "outcome", null: false
    t.string "error_class"
    t.string "error_message"
    t.integer "duration_ms"
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_observability_attempts_on_created_at"
    t.index ["job_id"], name: "index_observability_attempts_on_job_id"
  end

  create_table "observability_nodes", force: :cascade do |t|
    t.string "node_id", null: false
    t.string "kind", null: false
    t.string "name", null: false
    t.integer "version"
    t.string "source"
    t.string "parent_id"
    t.string "correlation_id"
    t.string "published_by_job_id"
    t.integer "subscriber_count"
    t.string "outcome"
    t.datetime "created_at", null: false
    t.index ["correlation_id"], name: "index_observability_nodes_on_correlation_id"
    t.index ["created_at"], name: "index_observability_nodes_on_created_at"
    t.index ["node_id"], name: "index_observability_nodes_on_node_id", unique: true
    t.index ["parent_id"], name: "index_observability_nodes_on_parent_id"
  end

  create_table "orders_line_items", force: :cascade do |t|
    t.integer "order_id", null: false
    t.string "sku", null: false
    t.string "name", null: false
    t.integer "quantity", null: false
    t.integer "unit_price_cents", null: false
    t.index ["order_id"], name: "index_orders_line_items_on_order_id"
  end

  create_table "orders_orders", force: :cascade do |t|
    t.string "reference", null: false
    t.string "basket_fingerprint", null: false
    t.string "state", null: false
    t.string "customer_id", null: false
    t.string "customer_name", null: false
    t.string "customer_email", null: false
    t.string "shipping_address", null: false
    t.integer "total_cents", null: false
    t.string "currency", null: false
    t.string "correlation_id", null: false
    t.string "cancel_reason"
    t.string "attention_reason"
    t.string "tracking_code"
    t.datetime "placed_at", null: false
    t.datetime "paid_at"
    t.datetime "shipped_at"
    t.datetime "delivered_at"
    t.datetime "cancelled_at"
    t.datetime "cancellation_announced_at"
    t.datetime "return_requested_at"
    t.datetime "refunded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["correlation_id"], name: "index_orders_orders_on_correlation_id"
    t.index ["customer_id"], name: "index_orders_orders_on_customer_id"
    t.index ["reference"], name: "index_orders_orders_on_reference", unique: true
    t.index ["state", "placed_at"], name: "index_orders_orders_on_state_and_placed_at"
  end

  create_table "payments_payments", force: :cascade do |t|
    t.string "reference", null: false
    t.integer "amount_cents", null: false
    t.string "currency", null: false
    t.string "state", null: false
    t.string "authorization_code", null: false
    t.string "failure_reason"
    t.datetime "captured_at"
    t.datetime "voided_at"
    t.datetime "refunded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["reference"], name: "index_payments_payments_on_reference", unique: true
  end

  create_table "platform_fault_settings", force: :cascade do |t|
    t.float "authorization_decline_rate", default: 0.0, null: false
    t.float "capture_refusal_rate", default: 0.0, null: false
    t.float "refund_refusal_rate", default: 0.0, null: false
    t.float "temporary_failure_rate", default: 0.0, null: false
    t.integer "carrier_delay_seconds", default: 4, null: false
    t.json "forced_failures", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "catalog_reservations", "catalog_products", column: "product_id"
  add_foreign_key "orders_line_items", "orders_orders", column: "order_id"
end
