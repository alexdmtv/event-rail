# The shop's jobs the console can make fail: every concrete job that takes part in flows and
# retries a failure on its own. A job without such a retry would fail for good at its first
# forced failure, and could strand an order -- the opposite of what the control demonstrates.
module ForceableJobs
  def self.names
    Platform::ApplicationJob.descendants.select { |job| job.name && job.descendants.empty? && retries_forced_failures?(job) }.map(&:name).sort
  end

  def self.find!(name) = names.include?(name) ? name : raise(ActionController::BadRequest, "unknown job #{name}")

  def self.retries_forced_failures?(job)
    job.rescue_handlers.any? do |class_name, _|
      handled = class_name.safe_constantize
      handled.is_a?(Class) && Platform::InjectedFault <= handled
    end
  end
end
