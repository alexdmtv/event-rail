module ApplicationHelper
  MODULES = %w[ Catalog Payments Fulfillment Orders Notifications Loyalty Observability Simulation Platform Console ].freeze

  # Every module has one color across the console: in the feed, the flow tree and the graph.
  def module_class(name) = "module-#{name.to_s.downcase}"

  def module_badge(name) = tag.span(name, class: [ "badge", module_class(name) ])

  def module_of(name) = Observability::Api.module_of_name(name)

  def event_label(type, version = nil)
    safe_join([ tag.code(type), (tag.span("v#{version}", class: "version") if version) ].compact, " ")
  end

  def money(cents, currency = "EUR") = number_to_currency(cents / 100.0, unit: currency == "EUR" ? "€" : "#{currency} ")

  def state_pill(state)
    state.present? ? tag.span(state.to_s.humanize.downcase, class: [ "pill", "state-#{state.to_s.dasherize}" ]) : tag.span("—", class: "muted")
  end

  def ago(time) = time ? tag.time("#{time_ago_in_words(time, include_seconds: true)} ago", datetime: time.iso8601, title: time.to_fs(:long)) : "—"

  def percent(rate) = (rate * 100).round

  # Stable element IDs let Turbo's morphing match list items across refreshes.
  def dom_id_for(publication) = "event-#{publication.event_id}"
end
