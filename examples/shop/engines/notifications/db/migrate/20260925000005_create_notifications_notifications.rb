class CreateNotificationsNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications_notifications do |t|
      t.string :event_id, null: false
      t.string :kind, null: false
      t.string :order_id, null: false, index: true
      t.string :customer_email, null: false
      t.string :subject, null: false
      t.text :body, null: false
      t.datetime :created_at, null: false
      # One notification per event and kind: a redelivered event records nothing new.
      t.index [ :event_id, :kind ], unique: true
    end
  end
end
