module Simulation
  # What the developer console controls and reads of the simulator.
  module Api
    State = Data.define(:running, :orders_per_minute, :cancel_rate, :return_rate, :placed_count, :rejected_count, :last_rejection)
    Customer = Data.define(:id, :name, :email, :address)

    class << self
      def state
        settings = Simulation::Settings.current
        State.new(**settings.slice(:running, :orders_per_minute, :cancel_rate, :return_rate, :placed_count, :rejected_count, :last_rejection).symbolize_keys)
      end

      def start = Simulation::Settings.current.update!(running: true)
      def stop = Simulation::Settings.current.update!(running: false)

      def configure(orders_per_minute:, cancel_rate:, return_rate:)
        Simulation::Settings.current.update!(orders_per_minute: orders_per_minute, cancel_rate: cancel_rate, return_rate: return_rate)
      end

      # One second of simulated customers, now.
      def tick = Simulation::TickJob.perform_now

      def customers
        Simulation::Customer.order(:name).map { |customer| Customer.new(id: customer.customer_id, name: customer.name, email: customer.email, address: customer.address) }
      end

      def customer_snapshot(customer_id) = Simulation::Customer.find_by!(customer_id: customer_id).snapshot
    end
  end
end
