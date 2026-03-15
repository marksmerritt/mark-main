import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["icon"]

  connect() {
    const saved = localStorage.getItem("theme")
    if (saved === "dark") {
      document.documentElement.setAttribute("data-theme", "dark")
    } else if (saved === "light") {
      document.documentElement.removeAttribute("data-theme")
    } else {
      // No preference saved — respect OS setting (CSS @media handles it)
    }
    this.updateIcon()
  }

  toggle() {
    const isDark = document.documentElement.getAttribute("data-theme") === "dark"
    if (isDark) {
      document.documentElement.removeAttribute("data-theme")
      localStorage.setItem("theme", "light")
    } else {
      document.documentElement.setAttribute("data-theme", "dark")
      localStorage.setItem("theme", "dark")
    }
    this.updateIcon()
  }

  updateIcon() {
    if (!this.hasIconTarget) return
    const isDark = document.documentElement.getAttribute("data-theme") === "dark"
    this.iconTarget.textContent = isDark ? "light_mode" : "dark_mode"
  }
}
