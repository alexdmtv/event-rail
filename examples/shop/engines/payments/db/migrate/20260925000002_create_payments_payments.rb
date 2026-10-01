class CreatePaymentsPayments < ActiveRecord::Migration[8.1]
  def change
    create_table :payments_payments do |t|
      t.string :reference, null: false, index: { unique: true }
      t.integer :amount_cents, null: false
      t.string :currency, null: false
      t.string :state, null: false
      t.string :authorization_code, null: false
      t.string :failure_reason
      # The provider call waiting to be made or answered, when it was sent, and which call it
      # is: one call at a time, so a capture and a void of the same authorization never both
      # reach the provider, and the generation tells a job carrying an earlier call that it has
      # been answered or replaced.
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
