# The shop's jobs the console can make fail: every concrete job that takes part in flows.
module ForceableJobs
  def self.names
    Platform::ApplicationJob.descendants.select { |job| job.name && job.descendants.empty? }.map(&:name).sort
  end

  def self.find!(name) = names.include?(name) ? name : raise(ActionController::BadRequest, "unknown job #{name}")
end
