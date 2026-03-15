import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "trigger"]

  show() {
    this.contentTargets.forEach(el => el.classList.remove("hidden"))
    this.triggerTargets.forEach(el => el.classList.add("hidden"))
  }

  hide() {
    this.contentTargets.forEach(el => el.classList.add("hidden"))
    this.triggerTargets.forEach(el => el.classList.remove("hidden"))
  }

  toggle() {
    this.contentTargets.forEach(el => el.classList.toggle("hidden"))
  }
}
