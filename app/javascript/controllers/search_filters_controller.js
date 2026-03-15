import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab", "section", "input"]

  filter(event) {
    const filter = event.currentTarget.dataset.filter

    // Update active tab
    this.tabTargets.forEach(tab => {
      tab.classList.toggle("active", tab.dataset.filter === filter)
    })

    // Show/hide sections
    this.sectionTargets.forEach(section => {
      if (filter === "all") {
        section.style.display = ""
      } else {
        section.style.display = section.dataset.section === filter ? "" : "none"
      }
    })
  }

  handleKey(event) {
    if (event.key === "Escape") {
      this.inputTarget.blur()
    }
  }
}
