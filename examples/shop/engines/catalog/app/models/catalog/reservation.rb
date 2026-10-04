module Catalog
  # Stock set aside under a caller's reference. Its lines never change; its state moves once:
  # held, then released, or shipped and later restocked.
  class Reservation < ApplicationRecord
    has_many :lines, class_name: "ReservationLine", dependent: :delete_all

    # Its bang methods (shipped!) skip the reservation's transitions; never call them.
    enum :state, %w[ held released shipped restocked ].index_by(&:itself), validate: true

    # All items or none. A reference holds once: repeating it returns the first reservation,
    # whatever the items. The reference is claimed before the stock, so an identical retry waits
    # and gets the winner's reservation rather than finding the stock taken; products are locked
    # in ID order, as shipping and restocking take them, so no two can deadlock.
    def self.hold(reference, items)
      items.each do |sku, quantity|
        raise InvalidQuantity, "#{sku}: #{quantity.inspect} is not a positive quantity" unless quantity.is_a?(Integer) && quantity.positive?
      end

      find_by(reference:) || transaction(requires_new: true) do
        create!(reference:, state: "held").tap do |reservation|
          products = Product.where(sku: items.keys).order(:id).lock.index_by(&:sku)
          items.each do |sku, quantity|
            product = products[sku] or raise UnknownProduct, "unknown product #{sku}"
            product.ensure_available(quantity)
            reservation.lines.create!(product:, quantity:)
          end
        end
      end
    rescue ActiveRecord::RecordNotUnique
      find_by!(reference:)
    end

    # Safe to repeat. Only held stock is released.
    def release = update_if({ state: "held" }, state: "released", released_at: Time.current)

    # Takes the held stock off the shelf. Safe to repeat; a released reservation cannot ship.
    def ship
      update_if({ state: "held" }, state: "shipped", shipped_at: Time.current) do
        lines_by_product.each { |line| line.product.withdraw(line.quantity) }
      end
      raise "reservation #{reference} was released, so it cannot ship" if released?
    end

    # Puts shipped stock back on the shelf. Safe to repeat. Raises NotYetShipped while the stock
    # is still held, to be retried: ignoring it would lose the returned stock.
    def restock
      raise NotYetShipped, "reservation #{reference} has not shipped yet" if held?

      update_if({ state: "shipped" }, state: "restocked", restocked_at: Time.current) do
        lines_by_product.each { |line| line.product.receive(line.quantity) }
      end
    end

    private
      def lines_by_product = lines.includes(:product).sort_by(&:product_id)
  end
end
