class CreateFulfillmentTables < ActiveRecord::Migration[8.1]
  def change
    create_table :fulfillment_shipments do |t|
      t.string :reference, null: false, index: { unique: true }
      # A shipment cancelled before it was requested has no recipient: it only stops a
      # request still on its way from reviving it.
      t.string :recipient_name
      t.string :address
      t.json :items, null: false, default: {}
      t.string :state, null: false, default: "requested"
      t.string :tracking_code
      t.datetime :dispatched_at
      t.datetime :delivered_at
      t.datetime :cancelled_at
      t.timestamps
    end

    create_table :fulfillment_returns do |t|
      t.string :reference, null: false, index: { unique: true }
      t.string :state, null: false, default: "expected"
      t.datetime :received_at
      t.timestamps
    end
  end
end
