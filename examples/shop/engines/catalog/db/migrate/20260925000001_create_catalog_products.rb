class CreateCatalogProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_products do |t|
      t.string :sku, null: false, index: { unique: true }
      t.string :name, null: false
      t.integer :price_cents, null: false
      t.integer :on_hand, null: false, default: 0
      t.timestamps
      t.check_constraint "on_hand >= 0", name: "catalog_products_on_hand_not_negative"
    end

    create_table :catalog_reservations do |t|
      t.string :reference, null: false, index: { unique: true }
      t.string :state, null: false
      t.datetime :released_at
      t.datetime :shipped_at
      t.datetime :restocked_at
      t.timestamps
    end

    create_table :catalog_reservation_lines do |t|
      t.references :reservation, null: false, index: false, foreign_key: { to_table: :catalog_reservations }
      t.references :product, null: false, foreign_key: { to_table: :catalog_products }
      t.integer :quantity, null: false
      t.index [ :reservation_id, :product_id ], unique: true, name: "index_catalog_reservation_lines_on_reservation_and_product"
      t.check_constraint "quantity > 0", name: "catalog_reservation_lines_quantity_positive"
    end
  end
end
