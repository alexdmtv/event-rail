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

ActiveRecord::Schema[8.1].define(version: 2026_09_25_000001) do
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

  add_foreign_key "catalog_reservations", "catalog_products", column: "product_id"
end
