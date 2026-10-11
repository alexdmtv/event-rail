class CreatePlatformStagedJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :platform_staged_jobs do |t|
      t.string :job_id, null: false, index: true
      t.string :job_class, null: false
      t.json :payload, null: false
      t.string :correlation_id
      t.string :causation_id
      # The W3C trace context it was staged in, so the job joins its trace however late it leaves.
      t.json :trace_context
      t.datetime :reported_at
      t.datetime :parked_at
      t.datetime :created_at, null: false, index: true
    end
  end
end
