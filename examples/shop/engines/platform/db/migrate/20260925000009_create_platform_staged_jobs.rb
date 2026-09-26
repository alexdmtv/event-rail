class CreatePlatformStagedJobs < ActiveRecord::Migration[8.1]
  def change
    # Jobs a boundary started in the same transaction as the business records they belong to,
    # waiting to be handed to the queue, which keeps its own database. A row lives in the store
    # of the records it commits with; it is deleted once the queue has accepted its job.
    create_table :platform_staged_jobs do |t|
      t.string :job_id, null: false, index: true
      t.string :job_class, null: false
      t.json :payload, null: false
      # The flow the job was staged in, so that handing it over later keeps it in that flow.
      t.string :correlation_id
      t.string :causation_id
      t.datetime :created_at, null: false, index: true
    end
  end
end
