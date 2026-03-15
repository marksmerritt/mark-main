import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["textarea"]

  bold() { this.wrapSelection("**", "**") }
  italic() { this.wrapSelection("*", "*") }
  strikethrough() { this.wrapSelection("~~", "~~") }
  code() { this.wrapSelection("`", "`") }

  heading() {
    this.prefixLine("## ")
  }

  bullet() {
    this.prefixLine("- ")
  }

  numbered() {
    const textarea = this.textareaTarget
    const start = textarea.selectionStart
    const lineStart = textarea.value.lastIndexOf("\n", start - 1) + 1
    const before = textarea.value.substring(0, lineStart)
    const after = textarea.value.substring(lineStart)

    // Count existing numbered items
    const lines = before.split("\n")
    let num = 1
    for (let i = lines.length - 1; i >= 0; i--) {
      if (/^\d+\. /.test(lines[i])) num++
      else break
    }

    textarea.value = before + `${num}. ` + after
    textarea.selectionStart = textarea.selectionEnd = lineStart + `${num}. `.length
    textarea.focus()
    textarea.dispatchEvent(new Event("input"))
  }

  quote() {
    this.prefixLine("> ")
  }

  hr() {
    const textarea = this.textareaTarget
    const pos = textarea.selectionEnd
    const before = textarea.value.substring(0, pos)
    const after = textarea.value.substring(pos)
    const insert = "\n\n---\n\n"
    textarea.value = before + insert + after
    textarea.selectionStart = textarea.selectionEnd = pos + insert.length
    textarea.focus()
    textarea.dispatchEvent(new Event("input"))
  }

  wrapSelection(before, after) {
    const textarea = this.textareaTarget
    const start = textarea.selectionStart
    const end = textarea.selectionEnd
    const selected = textarea.value.substring(start, end)
    const replacement = before + (selected || "text") + after

    textarea.value = textarea.value.substring(0, start) + replacement + textarea.value.substring(end)
    textarea.selectionStart = start + before.length
    textarea.selectionEnd = start + before.length + (selected || "text").length
    textarea.focus()
    textarea.dispatchEvent(new Event("input"))
  }

  prefixLine(prefix) {
    const textarea = this.textareaTarget
    const start = textarea.selectionStart
    const lineStart = textarea.value.lastIndexOf("\n", start - 1) + 1
    const before = textarea.value.substring(0, lineStart)
    const after = textarea.value.substring(lineStart)

    textarea.value = before + prefix + after
    textarea.selectionStart = textarea.selectionEnd = start + prefix.length
    textarea.focus()
    textarea.dispatchEvent(new Event("input"))
  }
}
