import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Submits the checkout form twice at once, with the same checkout key -- a double click, or
// a retry racing the first attempt -- and shows that both submissions got the same order.
export default class extends Controller {
  static targets = [ "result" ]

  async submit(event) {
    event.preventDefault()
    const form = this.element
    // The form's own authenticity token travels in its data.
    const send = () => fetch(form.action, { method: "POST", body: new FormData(form), headers: { "Accept": "application/json" } })
      .then((response) => response.json())

    const [ first, second ] = await Promise.all([ send(), send() ])
    if (first.error || second.error) {
      this.resultTarget.textContent = `Rejected: ${first.error || second.error}`
      return
    }
    this.resultTarget.textContent = `Both submissions returned order #${first.order_id}` +
      (first.order_id === second.order_id ? " — one order." : ` and #${second.order_id}.`)
    setTimeout(() => Turbo.visit(first.url), 1500)
  }
}
