module Observability
  # What the developer console reads: recent publications, one flow as a causal tree, and the
  # wiring observed between publishers and subscribers.
  module Api
    Publication = Data.define(:event_id, :event_type, :version, :module_name, :correlation_id, :created_at)
    Attempt = Data.define(:number, :outcome, :error_class, :error_message, :duration_ms, :created_at)
    Step = Data.define(:kind, :id, :name, :version, :module_name, :outcome, :created_at, :attempts, :children) do
      def event? = kind == "event"
      def failed_attempts = attempts.count { |attempt| attempt.outcome == "failed" }
      def succeeded? = attempts.any? { |attempt| attempt.outcome == "succeeded" }
      def size = 1 + children.sum(&:size)
    end
    Wiring = Data.define(:event_type, :publishers, :subscribers)

    class << self
      def recent_publications(limit: 30)
        Observability::Node.events.order(id: :desc).limit(limit).map do |node|
          Publication.new(event_id: node.node_id, event_type: node.name, version: node.version, module_name: module_of(node),
            correlation_id: node.correlation_id, created_at: node.created_at)
        end
      end

      # The flow of one correlation, as trees: each event under the job that published it
      # (or its causation), each job under the event it delivers or the job that enqueued it.
      def flow(correlation_id)
        nodes = Observability::Node.where(correlation_id: correlation_id).includes(:attempts).order(:id).to_a
        by_id = nodes.index_by(&:node_id)
        children = Hash.new { |hash, key| hash[key] = [] }
        roots = []
        nodes.each do |node|
          parent = node.published_by_job_id.presence_in(by_id) || node.parent_id.presence_in(by_id)
          parent ? children[parent] << node : roots << node
        end
        roots.map { |node| step(node, children) }
      end

      # For each event type seen, who published it and which subscribers were seen reacting.
      def wiring
        publishers = Observability::Node.events.group(:name).distinct.pluck(:name, :source).group_by(&:first)
        subscribers = Observability::Node.jobs.joins("JOIN observability_nodes events ON events.node_id = observability_nodes.parent_id AND events.kind = 'event'")
          .distinct.pluck("events.name", "observability_nodes.name").group_by(&:first)
        publishers.keys.sort.map do |type|
          Wiring.new(event_type: type, publishers: publishers[type].map(&:last).uniq.sort,
            subscribers: subscribers.fetch(type, []).map(&:last).uniq.sort)
        end
      end

      def module_of_name(name) = name.include?("::") ? name.split("::").first : name.split(".").first.camelize

      private
        def step(node, children)
          Step.new(
            kind: node.kind, id: node.node_id, name: node.name, version: node.version, module_name: module_of(node),
            outcome: node.outcome, created_at: node.created_at,
            attempts: node.attempts.map { |attempt| Attempt.new(**attempt.slice(:number, :outcome, :error_class, :error_message, :duration_ms, :created_at).symbolize_keys) },
            children: children[node.node_id].map { |child| step(child, children) }
          )
        end

        def module_of(node) = module_of_name(node.name)
    end
  end
end
