class CreateSimulationTables < ActiveRecord::Migration[8.1]
  def change
    create_table :simulation_customers do |t|
      t.string :customer_id, null: false, index: { unique: true }
      t.string :name, null: false
      t.string :email, null: false
      t.string :address, null: false
    end

    create_table :simulation_settings do |t|
      t.boolean :running, null: false, default: false
      t.integer :orders_per_minute, null: false, default: 20
      t.float :cancel_rate, null: false, default: 0.1
      t.float :return_rate, null: false, default: 0.1
      t.integer :placed_count, null: false, default: 0
      t.integer :rejected_count, null: false, default: 0
      t.string :last_rejection
      t.timestamps
    end
  end
end
