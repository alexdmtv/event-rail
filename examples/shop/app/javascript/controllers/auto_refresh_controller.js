import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Keeps a page current while the shop runs: every couple of seconds it revisits the page,
// and Turbo morphs in what changed, keeping the scroll position (see the meta tags in the
// layout). A form holding input the developer has not submitted is marked permanent, so the
// morph leaves it alone while the rest of the page keeps updating. The refresh waits only
// while a field has focus, and while the tab is hidden.
export default class extends Controller {
  static values = { interval: { type: Number, default: 2000 } }

  connect() {
    this.element.addEventListener("input", this.keep)
    this.element.addEventListener("submit", this.release)
    this.element.addEventListener("reset", this.release)
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
    this.element.removeEventListener("input", this.keep)
    this.element.removeEventListener("submit", this.release)
    this.element.removeEventListener("reset", this.release)
  }

  refresh() {
    if (document.hidden || this.typing) return
    Turbo.visit(window.location.href, { action: "replace" })
  }

  get typing() {
    const active = document.activeElement
    return active && this.element.contains(active) && active.matches("input, select, textarea")
  }

  // Turbo keeps a permanent element as it is when it morphs the page; it needs an id.
  keep = (event) => {
    const form = event.target.form
    if (form?.id) form.setAttribute("data-turbo-permanent", "")
  }

  release = (event) => { event.target.removeAttribute("data-turbo-permanent") }
}
