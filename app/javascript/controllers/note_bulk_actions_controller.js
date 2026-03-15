import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "bar", "count", "tagSelect", "notebookSelect"]
  static values = {
    bulkTagUrl: String,
    bulkMoveUrl: String,
    bulkDeleteUrl: String,
    bulkFavoriteUrl: String,
    bulkPinUrl: String,
    csrfToken: String
  }

  toggle() {
    this.updateBar()
  }

  toggleAll(event) {
    const checked = event.target.checked
    this.checkboxTargets.forEach(cb => cb.checked = checked)
    this.updateBar()
  }

  clear() {
    this.checkboxTargets.forEach(cb => cb.checked = false)
    this.updateBar()
  }

  async bulkTag() {
    const ids = this.selectedIds()
    if (ids.length === 0) return

    if (!this.hasTagSelectTarget) return
    const tagIds = Array.from(this.tagSelectTarget.selectedOptions).map(o => o.value)
    if (tagIds.length === 0) {
      alert("Select at least one tag to apply.")
      return
    }

    try {
      const response = await fetch(this.bulkTagUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfTokenValue
        },
        body: JSON.stringify({ note_ids: ids, tag_ids: tagIds })
      })
      const result = await response.json()
      if (result.updated !== undefined) {
        window.location.reload()
      } else {
        alert(result.error || "Failed to tag notes.")
      }
    } catch (e) {
      alert("Failed to tag notes.")
    }
  }

  async bulkMove() {
    const ids = this.selectedIds()
    if (ids.length === 0) return

    if (!this.hasNotebookSelectTarget) return
    const notebookId = this.notebookSelectTarget.value
    if (!notebookId) {
      alert("Select a notebook to move notes to.")
      return
    }

    try {
      const response = await fetch(this.bulkMoveUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfTokenValue
        },
        body: JSON.stringify({ note_ids: ids, notebook_id: notebookId })
      })
      const result = await response.json()
      if (result.updated !== undefined) {
        window.location.reload()
      } else {
        alert(result.error || "Failed to move notes.")
      }
    } catch (e) {
      alert("Failed to move notes.")
    }
  }

  async bulkDelete() {
    const ids = this.selectedIds()
    if (ids.length === 0) return

    if (!confirm(`Move ${ids.length} note(s) to trash?`)) return

    try {
      const response = await fetch(this.bulkDeleteUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfTokenValue
        },
        body: JSON.stringify({ note_ids: ids })
      })
      const result = await response.json()
      if (result.deleted !== undefined) {
        window.location.reload()
      } else {
        alert(result.error || "Failed to delete notes.")
      }
    } catch (e) {
      alert("Failed to delete notes.")
    }
  }

  async bulkFavorite() {
    const ids = this.selectedIds()
    if (ids.length === 0) return

    try {
      const response = await fetch(this.bulkFavoriteUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfTokenValue
        },
        body: JSON.stringify({ note_ids: ids, favorited: true })
      })
      const result = await response.json()
      if (result.updated !== undefined) {
        window.location.reload()
      } else {
        alert(result.error || "Failed to favorite notes.")
      }
    } catch (e) {
      alert("Failed to favorite notes.")
    }
  }

  async bulkPin() {
    const ids = this.selectedIds()
    if (ids.length === 0) return

    try {
      const response = await fetch(this.bulkPinUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfTokenValue
        },
        body: JSON.stringify({ note_ids: ids, pinned: true })
      })
      const result = await response.json()
      if (result.updated !== undefined) {
        window.location.reload()
      } else {
        alert(result.error || "Failed to pin notes.")
      }
    } catch (e) {
      alert("Failed to pin notes.")
    }
  }

  updateBar() {
    const count = this.selectedIds().length
    this.countTarget.textContent = count

    if (count > 0) {
      this.barTarget.classList.remove("hidden")
    } else {
      this.barTarget.classList.add("hidden")
    }
  }

  selectedIds() {
    return this.checkboxTargets.filter(cb => cb.checked).map(cb => cb.value)
  }
}
