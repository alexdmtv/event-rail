# Scheduled work, as tests reach it. Nothing runs the schedule in tests, so a test enqueues a
# task from config/recurring.yml by its key, then runs the queue as it would any other jobs:
# no module needs an Api method for tests to start its scheduled work, and a test that does
# this also proves the schedule names a real job.
#
# Solid Queue's own RecurringTask can't be used: it is an Active Record model, and the test
# environment has no queue database. So the checks below are the ones it makes.
module Schedule
  def enqueue_scheduled(key)
    task = scheduled_tasks.fetch(key.to_sym) { raise KeyError, "config/recurring.yml has no #{key} task for #{Rails.env}" }
    job = task[:class] ? task[:class].constantize : SolidQueue::RecurringJob
    arguments = task[:class] ? Array(task[:args]) : [ task[:command] ]
    job.set(**task.slice(:queue, :priority)).perform_later(*arguments)
  end

  # The problems Solid Queue's scheduler would reject a task for, by key: a job class that
  # doesn't exist, no class or command at all, or a schedule that isn't one cron.
  def schedule_problems
    scheduled_tasks.filter_map do |key, task|
      problem =
        if task[:class].nil? && task[:command].nil? then "has neither a class nor a command"
        elsif task[:class] && !(task[:class].safe_constantize.is_a?(Class) && task[:class].constantize < ActiveJob::Base) then "names no job: #{task[:class]}"
        elsif !(Fugit.parse(task[:schedule].to_s, multi: :fail).is_a?(Fugit::Cron) rescue false) then "has an unsupported schedule: #{task[:schedule].inspect}"
        end
      "#{key} #{problem}" if problem
    end
  end

  private
    def scheduled_tasks
      ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml")).deep_symbolize_keys.fetch(Rails.env.to_sym)
    end
end
