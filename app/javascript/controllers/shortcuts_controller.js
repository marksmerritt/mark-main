import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
  }

  handleKeydown(event) {
    const tag = event.target.tagName.toLowerCase()
    if (tag === "input" || tag === "textarea" || tag === "select" || event.target.isContentEditable) {
      if (event.key === "Escape") event.target.blur()
      return
    }

    if (event.ctrlKey || event.metaKey || event.altKey) return

    switch (event.key) {
      case "n":
        event.preventDefault()
        window.Turbo.visit("/trades/new")
        break
      case "j":
        event.preventDefault()
        window.Turbo.visit("/journal_entries/new")
        break
      case "m":
        event.preventDefault()
        window.Turbo.visit("/notes/new")
        break
      case "t":
        event.preventDefault()
        window.Turbo.visit("/trades")
        break
      case "r":
        event.preventDefault()
        window.Turbo.visit("/reports/overview")
        break
      case "h":
        event.preventDefault()
        window.Turbo.visit("/")
        break
      case "s":
        event.preventDefault()
        window.Turbo.visit("/search")
        break
      case "p":
        event.preventDefault()
        window.Turbo.visit("/trade_plans")
        break
      case "w":
        event.preventDefault()
        window.Turbo.visit("/watchlists")
        break
      case "c":
        event.preventDefault()
        window.Turbo.visit("/position_calculator")
        break
      case "e":
        event.preventDefault()
        window.Turbo.visit("/reports/equity_curve")
        break
      case "d":
        event.preventDefault()
        window.Turbo.visit("/reports/scorecard")
        break
      case "b":
        event.preventDefault()
        window.Turbo.visit("/playbooks")
        break
      case "v":
        event.preventDefault()
        window.Turbo.visit("/trades/review")
        break
      case "g":
        event.preventDefault()
        window.Turbo.visit("/budget")
        break
      case "q":
        event.preventDefault()
        document.querySelector("[data-controller='quick-journal'] [data-quick-journal-target='modal']")?.classList.remove("hidden")
        break
      case "/":
        event.preventDefault()
        const searchInput = document.querySelector("input[name='symbol'], input[name='q'], input[type='search'], .form-control[type='text']")
        if (searchInput) searchInput.focus()
        break
      case "?":
        event.preventDefault()
        this.toggleHelp()
        break
      case "Escape":
        this.dismissHelp()
        break
    }
  }

  toggleHelp() {
    const existing = document.getElementById("shortcuts-modal")
    if (existing) { existing.remove(); return }

    const modal = document.createElement("div")
    modal.id = "shortcuts-modal"
    modal.className = "shortcuts-overlay"
    modal.addEventListener("click", (e) => { if (e.target === modal) modal.remove() })
    modal.innerHTML = `
      <div class="shortcuts-dialog" style="max-width: 36rem;">
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
          <h2>Keyboard Shortcuts</h2>
          <button class="btn-icon" onclick="this.closest('.shortcuts-overlay').remove()" title="Close">
            <span class="material-icons-outlined">close</span>
          </button>
        </div>
        <div class="shortcuts-sections">
          <div class="shortcuts-section">
            <h4>Navigation</h4>
            <div class="shortcuts-grid">
              <div class="shortcut"><kbd>h</kbd> <span>Home / Dashboard</span></div>
              <div class="shortcut"><kbd>t</kbd> <span>Trades</span></div>
              <div class="shortcut"><kbd>r</kbd> <span>Reports Overview</span></div>
              <div class="shortcut"><kbd>e</kbd> <span>Equity Curve</span></div>
              <div class="shortcut"><kbd>d</kbd> <span>Scorecard</span></div>
              <div class="shortcut"><kbd>p</kbd> <span>Trade Plans</span></div>
              <div class="shortcut"><kbd>b</kbd> <span>Playbooks</span></div>
              <div class="shortcut"><kbd>w</kbd> <span>Watchlist</span></div>
              <div class="shortcut"><kbd>c</kbd> <span>Calculator</span></div>
              <div class="shortcut"><kbd>s</kbd> <span>Search</span></div>
              <div class="shortcut"><kbd>g</kbd> <span>Budget Dashboard</span></div>
            </div>
          </div>
          <div class="shortcuts-section">
            <h4>Actions</h4>
            <div class="shortcuts-grid">
              <div class="shortcut"><kbd>n</kbd> <span>New Trade</span></div>
              <div class="shortcut"><kbd>a</kbd> <span>Quick Add Trade</span></div>
              <div class="shortcut"><kbd>j</kbd> <span>New Journal Entry</span></div>
              <div class="shortcut"><kbd>m</kbd> <span>New Note</span></div>
              <div class="shortcut"><kbd>v</kbd> <span>Trade Review Mode</span></div>
              <div class="shortcut"><kbd>q</kbd> <span>Quick Journal</span></div>
              <div class="shortcut"><kbd>x</kbd> <span>Quick Expense</span></div>
              <div class="shortcut"><kbd>/</kbd> <span>Focus Search Input</span></div>
            </div>
          </div>
          <div class="shortcuts-section">
            <h4>General</h4>
            <div class="shortcuts-grid">
              <div class="shortcut"><kbd>⌘K</kbd> <span>Command Palette</span></div>
              <div class="shortcut"><kbd>?</kbd> <span>This Help</span></div>
              <div class="shortcut"><kbd>Esc</kbd> <span>Dismiss / Blur</span></div>
            </div>
          </div>
        </div>
      </div>
    `
    document.body.appendChild(modal)
  }

  dismissHelp() {
    const modal = document.getElementById("shortcuts-modal")
    if (modal) modal.remove()
  }
}
