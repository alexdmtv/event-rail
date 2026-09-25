import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Keeps a page current while the shop runs: every couple of seconds it revisits the page,
// and Turbo morphs in what changed, keeping the scroll position (see the meta tags in the
// layout). It pauses while the developer is typing into a form on the page, so a refresh
// never discards their input, and while the tab is hidden.
export default class extends Controller {
  static values = { interval: { type: Number, default: 2000 } }

  connect() {
    this.dirty = false
    this.element.addEventListener("input", this.markDirty)
    this.element.addEventListener("submit", this.markClean)
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
    this.element.removeEventListener("input", this.markDirty)
    this.element.removeEventListener("submit", this.markClean)
  }

  refresh() {
    if (document.hidden || this.dirty || this.typing) return
    Turbo.visit(window.location.href, { action: "replace" })
  }

  get typing() {
    const active = document.activeElement
    return active && this.element.contains(active) && active.matches("input, select, textarea")
  }

  markDirty = () => { this.dirty = true }
  markClean = () => { this.dirty = false }
}
