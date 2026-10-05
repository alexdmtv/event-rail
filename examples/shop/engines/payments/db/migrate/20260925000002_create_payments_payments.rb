class CreatePaymentsPayments < ActiveRecord::Migration[8.1]
  def change
    create_table :payments_payments do |t|
      t.string :reference, null: false, index: { unique: true }
      t.integer :amount_cents, null: false
      t.string :currency, null: false
      t.string :state, null: false
      t.string :authorization_code, null: false
      # A release, once asked for, stays asked for: no capture starts after it.
      t.datetime :release_requested_at
      t.datetime :captured_at
      t.datetime :voided_at
      t.datetime :refunded_at
      t.timestamps
      t.check_constraint "state IN ('authorized', 'captured', 'voided', 'refunded')", name: "payments_payments_state_known"
    end

    create_table :payments_provider_calls do |t|
      t.references :payment, null: false, index: false, foreign_key: { to_table: :payments_payments }
      t.string :kind, null: false
      t.string :state, null: false
      t.string :idempotency_key, null: false, index: { unique: true }
      t.datetime :sent_at
      t.datetime :answered_at
      t.string :failure_reason
      t.timestamps
      # One call of each kind per payment, so a refused capture is never asked again.
      t.index [ :payment_id, :kind ], unique: true, name: "index_payments_provider_calls_on_payment_and_kind"
      # At most one outstanding call per payment, so a capture and a void never both reach the provider.
      t.index :payment_id, unique: true, where: "state IN ('pending', 'sent')", name: "index_payments_provider_calls_one_outstanding"
      t.check_constraint "kind IN ('capture', 'void', 'refund')", name: "payments_provider_calls_kind_known"
      t.check_constraint "state IN ('pending', 'sent', 'succeeded', 'refused', 'superseded')", name: "payments_provider_calls_state_known"
    end
  end
end
