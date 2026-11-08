require "fugit" # what Solid Queue parses schedules with

module Platform
  module TestSupport
    # Enqueues a task from config/recurring.yml by its key. Solid Queue's RecurringTask is an
    # Active Record model and tests have no queue database, so its checks are repeated here.
    module Schedule
      def enqueue_scheduled(key)
        task = scheduled_tasks.fetch(key.to_sym) { raise KeyError, "config/recurring.yml has no #{key} task for #{Rails.env}" }
        job = task[:class] ? task[:class].constantize : SolidQueue::RecurringJob
        arguments = task[:class] ? Array(task[:args]) : [ task[:command] ]
        job.set(**task.slice(:queue, :priority)).perform_later(*arguments)
      end

      # What Solid Queue's scheduler would reject a task for, by key.
      def schedule_problems
        scheduled_tasks.filter_map do |key, task|
          problem =
            if task[:class].nil? && task[:command].nil? then "has neither a class nor a command"
            elsif task[:class] && !(task[:class].safe_constantize.is_a?(Class) && task[:class].constantize < ActiveJob::Base) then "names no job: #{task[:class]}"
            elsif !cron?(task[:schedule]) then "has an unsupported schedule: #{task[:schedule].inspect}"
            end
          "#{key} #{problem}" if problem
        end
      end

      private
        def cron?(schedule)
          Fugit.parse(schedule.to_s, multi: :fail).is_a?(Fugit::Cron)
        rescue ArgumentError
          false
        end

        def scheduled_tasks
          ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml")).deep_symbolize_keys.fetch(Rails.env.to_sym)
        end
    end
  end
end
