class CreateObservabilityRecords < ActiveRecord::Migration[8.1]
  def change
    # An event or a job in a flow. Its parent is the message that caused it: for an event, its
    # causation; for a job, the event it delivers or the job that enqueued it.
    create_table :observability_nodes do |t|
      t.string :node_id, null: false, index: { unique: true }
      t.string :kind, null: false
      t.string :name, null: false
      t.integer :version
      t.string :source
      t.string :parent_id, index: true
      t.string :correlation_id, index: true
      t.string :published_by_job_id
      t.integer :subscriber_count
      t.string :outcome
      t.datetime :created_at, null: false, index: true
    end

    # One attempt to perform a job.
    create_table :observability_attempts do |t|
      t.string :job_id, null: false, index: true
      t.string :job_class, null: false
      t.integer :number, null: false
      t.string :outcome, null: false
      t.string :error_class
      t.string :error_message
      t.integer :duration_ms
      t.datetime :created_at, null: false, index: true
    end
  end
end
