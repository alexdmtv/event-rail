class CreatePaymentsPayments < ActiveRecord::Migration[8.1]
  def change
    create_table :payments_payments do |t|
      t.string :reference, null: false, index: { unique: true }
      t.integer :amount_cents, null: false
      t.string :currency, null: false
      t.string :state, null: false
      t.string :authorization_code, null: false
      t.string :failure_reason
      t.datetime :captured_at
      t.datetime :voided_at
      t.datetime :refunded_at
      t.timestamps
    end
  end
end
