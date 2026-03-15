import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["badge", "dropdown", "list", "count"]
  static values = { url: String, open: Boolean }

  connect() {
    this.openValue = false
    this.loaded = false
    this.handleOutsideClick = this.handleOutsideClick.bind(this)
    document.addEventListener("click", this.handleOutsideClick)
    this.fetchCount()
  }

  disconnect() {
    document.removeEventListener("click", this.handleOutsideClick)
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    this.openValue = !this.openValue
    if (this.openValue && !this.loaded) {
      this.load()
    }
  }

  openValueChanged() {
    if (this.hasDropdownTarget) {
      this.dropdownTarget.classList.toggle("hidden", !this.openValue)
    }
  }

  handleOutsideClick(event) {
    if (this.openValue && !this.element.contains(event.target)) {
      this.openValue = false
    }
  }

  async fetchCount() {
    try {
      const response = await fetch(this.urlValue, {
        headers: { "Accept": "application/json" }
      })
      if (!response.ok) return
      const data = await response.json()
      if (this.hasBadgeTarget) {
        if (data.count > 0) {
          this.badgeTarget.textContent = data.count > 9 ? "9+" : data.count
          this.badgeTarget.classList.remove("hidden")
        } else {
          this.badgeTarget.classList.add("hidden")
        }
      }
    } catch {
      // silently fail
    }
  }

  async load() {
    if (!this.hasListTarget) return
    this.listTarget.innerHTML = '<div class="notif-loading"><span class="material-icons-outlined spin">sync</span></div>'

    try {
      const response = await fetch(this.urlValue, {
        headers: { "Accept": "application/json" }
      })
      if (!response.ok) throw new Error("Failed")
      const data = await response.json()
      this.loaded = true
      this.render(data.notifications || [])
    } catch {
      this.listTarget.innerHTML = '<div class="notif-empty">Could not load notifications</div>'
    }
  }

  render(items) {
    if (items.length === 0) {
      this.listTarget.innerHTML = '<div class="notif-empty"><span class="material-icons-outlined">notifications_none</span><span>All caught up!</span></div>'
      return
    }

    const severityColor = {
      danger: "var(--negative)",
      warning: "#ea8600",
      success: "var(--positive)",
      info: "var(--primary)"
    }

    this.listTarget.innerHTML = items.map(item => {
      const color = severityColor[item.severity] || severityColor.info
      const url = item.url ? ` href="${item.url}"` : ""
      const tag = item.url ? "a" : "div"
      return `<${tag}${url} class="notif-item">
        <span class="notif-icon" style="color: ${color}">
          <span class="material-icons-outlined">${item.icon}</span>
        </span>
        <div class="notif-content">
          <span class="notif-title">${item.title}</span>
          <span class="notif-message">${item.message || ""}</span>
        </div>
      </${tag}>`
    }).join("")
  }
}
