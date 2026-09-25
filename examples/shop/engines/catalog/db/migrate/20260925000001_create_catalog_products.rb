class CreateCatalogProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_products do |t|
      t.string :sku, null: false, index: { unique: true }
      t.string :name, null: false
      t.integer :price_cents, null: false
      t.integer :on_hand, null: false, default: 0
      t.timestamps
    end

    create_table :catalog_reservations do |t|
      t.string :reservation_id, null: false
      t.references :product, null: false, foreign_key: { to_table: :catalog_products }
      t.integer :quantity, null: false
      t.string :state, null: false, default: "held"
      t.timestamps
      t.index [ :reservation_id, :product_id ], unique: true
    end
  end
end
