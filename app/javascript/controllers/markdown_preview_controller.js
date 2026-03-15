import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "preview", "toggle"]

  connect() {
    this.showPreview = false
  }

  toggle() {
    this.showPreview = !this.showPreview
    if (this.showPreview) {
      this.previewTarget.classList.remove("hidden")
      this.inputTarget.classList.add("hidden")
      this.toggleTarget.textContent = "Edit"
      this.renderPreview()
    } else {
      this.previewTarget.classList.add("hidden")
      this.inputTarget.classList.remove("hidden")
      this.toggleTarget.textContent = "Preview"
    }
  }

  renderPreview() {
    const text = this.inputTarget.value || ""
    this.previewTarget.innerHTML = this.markdownToHtml(text)
  }

  markdownToHtml(text) {
    if (!text.trim()) return "<p class=\"text-muted\">Nothing to preview.</p>"

    let html = this.escapeHtml(text)

    // Code blocks
    html = html.replace(/```(\w*)\n([\s\S]*?)```/g, "<pre><code>$2</code></pre>")
    // Inline code
    html = html.replace(/`([^`]+)`/g, "<code>$1</code>")
    // Bold
    html = html.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    // Italic
    html = html.replace(/\*(.+?)\*/g, "<em>$1</em>")
    // Headers
    html = html.replace(/^### (.+)$/gm, "<h3>$1</h3>")
    html = html.replace(/^## (.+)$/gm, "<h2>$1</h2>")
    html = html.replace(/^# (.+)$/gm, "<h1>$1</h1>")
    // Unordered lists
    html = html.replace(/^- (.+)$/gm, "<li>$1</li>")
    html = html.replace(/(<li>.*<\/li>\n?)+/g, "<ul>$&</ul>")
    // Horizontal rule
    html = html.replace(/^---$/gm, "<hr>")
    // Line breaks
    html = html.replace(/\n\n/g, "</p><p>")
    html = `<p>${html}</p>`
    // Clean up
    html = html.replace(/<p><\/p>/g, "")
    html = html.replace(/<p>(<h[1-3]>)/g, "$1")
    html = html.replace(/(<\/h[1-3]>)<\/p>/g, "$1")
    html = html.replace(/<p>(<ul>)/g, "$1")
    html = html.replace(/(<\/ul>)<\/p>/g, "$1")
    html = html.replace(/<p>(<pre>)/g, "$1")
    html = html.replace(/(<\/pre>)<\/p>/g, "$1")
    html = html.replace(/<p>(<hr>)<\/p>/g, "$1")

    return html
  }

  escapeHtml(text) {
    const map = { "&": "&amp;", "<": "&lt;", ">": "&gt;" }
    return text.replace(/[&<>]/g, m => map[m])
  }
}
