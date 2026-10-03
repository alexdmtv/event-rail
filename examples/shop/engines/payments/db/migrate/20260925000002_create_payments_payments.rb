class CreatePaymentsPayments < ActiveRecord::Migration[8.1]
  def change
    create_table :payments_payments do |t|
      t.string :reference, null: false, index: { unique: true }
      t.integer :amount_cents, null: false
      t.string :currency, null: false
      t.string :state, null: false
      t.string :authorization_code, null: false
      t.string :failure_reason
      # The one provider call in flight; the generation tells a job for an earlier call that it
      # was answered or replaced.
      t.string :pending_operation
      t.datetime :operation_sent_at
      t.integer :operation_generation, null: false, default: 0
      # A release, once asked for, stays asked for: no capture starts after it.
      t.datetime :release_requested_at
      t.datetime :captured_at
      t.datetime :voided_at
      t.datetime :refunded_at
      t.timestamps
    end
  end
end
