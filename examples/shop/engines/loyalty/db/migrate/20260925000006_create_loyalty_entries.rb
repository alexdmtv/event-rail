class CreateLoyaltyEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :loyalty_entries do |t|
      t.string :customer_id, null: false, index: true
      t.string :order_id, null: false
      t.string :kind, null: false
      t.integer :points, null: false
      t.string :event_id, null: false
      t.datetime :created_at, null: false
      # One award and at most one revocation per order: a redelivered event, or the same fact
      # republished, changes no balance.
      t.index [ :order_id, :kind ], unique: true
    end
  end
end
