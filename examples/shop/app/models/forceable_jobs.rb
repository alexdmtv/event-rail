# The shop's jobs the console can make fail: every concrete job of the shop's own. Every job
# retries a failure it cannot classify (see Platform::ApplicationJob), so a forced failure is
# retried, and the order carries on -- which is what the control demonstrates. Jobs declared by
# tests are left out.
module ForceableJobs
  def self.names
    Platform::ApplicationJob.descendants.select { |job| job.name && job.descendants.empty? && application_job?(job) }.map(&:name).sort
  end

  def self.find!(name) = names.include?(name) ? name : raise(ActionController::BadRequest, "unknown job #{name}")

  def self.application_job?(job) = Object.const_source_location(job.name)&.first.to_s.exclude?("/test/")
end
