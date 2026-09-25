class CreatePlatformFaultSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :platform_fault_settings do |t|
      t.float :authorization_decline_rate, null: false, default: 0.0
      t.float :capture_refusal_rate, null: false, default: 0.0
      t.float :refund_refusal_rate, null: false, default: 0.0
      t.float :temporary_failure_rate, null: false, default: 0.0
      t.integer :carrier_delay_seconds, null: false, default: 4
      t.json :forced_failures, null: false, default: {}
      t.timestamps
    end
  end
end
