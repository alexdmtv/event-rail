class CreatePlatformStagedJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :platform_staged_jobs do |t|
      t.string :job_id, null: false, index: true
      t.string :job_class, null: false
      t.json :payload, null: false
      t.string :correlation_id
      t.string :causation_id
      t.datetime :created_at, null: false, index: true
    end
  end
end
