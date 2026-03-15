import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "clock", "date", "status", "statusLabel", "statusDetail",
    "session", "sessionStatus", "countdown", "progress",
    "timeline", "timeMarker",
    "keyTime", "keyTimeStatus"
  ]

  // Session definitions matching the server-side data
  sessions = [
    { name: "US Pre-Market",    openH: 4,  openM: 0,  closeH: 9,  closeM: 30, crossesMidnight: false },
    { name: "US Regular Hours", openH: 9,  openM: 30, closeH: 16, closeM: 0,  crossesMidnight: false },
    { name: "US After Hours",   openH: 16, openM: 0,  closeH: 20, closeM: 0,  crossesMidnight: false },
    { name: "London",           openH: 3,  openM: 0,  closeH: 11, closeM: 30, crossesMidnight: false },
    { name: "Tokyo",            openH: 19, openM: 0,  closeH: 3,  closeM: 0,  crossesMidnight: true  },
    { name: "Sydney",           openH: 17, openM: 0,  closeH: 1,  closeM: 0,  crossesMidnight: true  }
  ]

  // Key times in minutes from midnight ET
  keyTimes = [
    240,   // 4:00 AM
    570,   // 9:30 AM
    585,   // 9:45 AM
    600,   // 10:00 AM
    690,   // 11:30 AM
    720,   // 12:00 PM
    840,   // 2:00 PM
    950,   // 3:50 PM
    960,   // 4:00 PM
    975,   // 4:15 PM
    1200   // 8:00 PM
  ]

  connect() {
    this.tick()
    this.timer = setInterval(() => this.tick(), 1000)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  tick() {
    const et = this.getETTime()
    this.updateClock(et)
    this.updateMarketStatus(et)
    this.updateSessions(et)
    this.updateTimeline(et)
    this.updateKeyTimes(et)
  }

  getETTime() {
    const now = new Date()
    const etString = now.toLocaleString("en-US", {
      timeZone: "America/New_York",
      hour12: false,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit"
    })
    // Format: "MM/DD/YYYY, HH:MM:SS"
    const parts = etString.split(", ")
    const timePart = parts[1] || "00:00:00"
    const [hours, minutes, seconds] = timePart.split(":").map(Number)

    // Get day of week in ET
    const dayName = new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", weekday: "long" }).format(now)
    const dateStr = new Intl.DateTimeFormat("en-US", {
      timeZone: "America/New_York",
      weekday: "long",
      month: "long",
      day: "numeric",
      year: "numeric"
    }).format(now)

    const isWeekend = dayName === "Saturday" || dayName === "Sunday"

    return {
      hours: hours === 24 ? 0 : hours,
      minutes,
      seconds,
      totalMinutes: (hours === 24 ? 0 : hours) * 60 + minutes,
      dayName,
      dateStr,
      isWeekend
    }
  }

  updateClock(et) {
    if (this.hasClockTarget) {
      const h = et.hours % 12 || 12
      const ampm = et.hours >= 12 ? "PM" : "AM"
      const timeStr = `${h}:${String(et.minutes).padStart(2, "0")}:${String(et.seconds).padStart(2, "0")} ${ampm}`
      this.clockTarget.textContent = timeStr
    }
    if (this.hasDateTarget) {
      this.dateTarget.textContent = et.dateStr
    }
  }

  updateMarketStatus(et) {
    if (!this.hasStatusLabelTarget) return

    const usRegular = this.sessions[1] // US Regular Hours
    const isOpen = this.isSessionOpen(usRegular, et) && !et.isWeekend

    if (isOpen) {
      this.statusLabelTarget.innerHTML = `<span style="color: var(--positive);">&#9679;</span> Markets are <span style="color: var(--positive);">OPEN</span>`
      const closeMin = usRegular.closeH * 60 + usRegular.closeM
      const remaining = closeMin - et.totalMinutes
      if (this.hasStatusDetailTarget) {
        this.statusDetailTarget.textContent = `Closes in ${this.formatDuration(remaining)}`
      }
      if (this.hasStatusTarget) {
        this.statusTarget.style.borderLeft = "4px solid var(--positive)"
      }
    } else {
      this.statusLabelTarget.innerHTML = `<span style="color: var(--negative);">&#9679;</span> Markets are <span style="color: var(--negative);">CLOSED</span>`
      if (this.hasStatusDetailTarget) {
        if (et.isWeekend) {
          this.statusDetailTarget.textContent = "Markets reopen Monday 9:30 AM ET"
        } else {
          const openMin = usRegular.openH * 60 + usRegular.openM
          let untilOpen = openMin - et.totalMinutes
          if (untilOpen <= 0) untilOpen += 1440
          this.statusDetailTarget.textContent = `Opens in ${this.formatDuration(untilOpen)}`
        }
      }
      if (this.hasStatusTarget) {
        this.statusTarget.style.borderLeft = "4px solid var(--negative)"
      }
    }
  }

  updateSessions(et) {
    this.sessions.forEach((session, i) => {
      const isOpen = this.isSessionOpen(session, et) && !et.isWeekend
      const statusEls = this.sessionStatusTargets.filter(el => el.dataset.statusIndex === String(i))
      const countdownEls = this.countdownTargets.filter(el => el.dataset.countdownIndex === String(i))
      const progressEls = this.progressTargets.filter(el => el.dataset.progressIndex === String(i))
      const cardEls = this.sessionTargets.filter(el => el.dataset.sessionIndex === String(i))

      statusEls.forEach(el => {
        if (isOpen) {
          el.innerHTML = `<span style="width: 8px; height: 8px; border-radius: 50%; background: var(--positive); display: inline-block; animation: pulse 2s infinite;"></span> <span style="color: var(--positive);">Open</span>`
        } else {
          el.innerHTML = `<span style="width: 8px; height: 8px; border-radius: 50%; background: var(--text-secondary); display: inline-block;"></span> <span style="color: var(--text-secondary);">Closed</span>`
        }
      })

      countdownEls.forEach(el => {
        if (et.isWeekend) {
          el.textContent = "Weekend - markets closed"
          el.style.color = "var(--text-secondary)"
        } else if (isOpen) {
          const remaining = this.minutesUntilClose(session, et)
          el.textContent = `Closes in ${this.formatDuration(remaining)}`
          el.style.color = "var(--positive)"
        } else {
          const untilOpen = this.minutesUntilOpen(session, et)
          el.textContent = `Opens in ${this.formatDuration(untilOpen)}`
          el.style.color = "var(--text-secondary)"
        }
      })

      progressEls.forEach(el => {
        if (isOpen) {
          const progress = this.sessionProgress(session, et)
          el.style.width = `${progress}%`
        } else {
          el.style.width = "0%"
        }
      })

      cardEls.forEach(el => {
        if (isOpen) {
          el.style.boxShadow = "0 0 0 1px var(--positive), 0 4px 12px rgba(0,0,0,0.1)"
        } else {
          el.style.boxShadow = ""
        }
      })
    })
  }

  updateTimeline(et) {
    if (!this.hasTimeMarkerTarget) return
    const pct = (et.totalMinutes + et.seconds / 60) / 1440 * 100
    this.timeMarkerTarget.style.left = `${pct}%`
  }

  updateKeyTimes(et) {
    if (!this.hasKeyTimeStatusTarget) return

    this.keyTimeStatusTargets.forEach((el, i) => {
      if (i >= this.keyTimes.length) return

      const keyMin = this.keyTimes[i]
      const diff = keyMin - et.totalMinutes

      if (et.isWeekend) {
        el.textContent = ""
        el.style.color = "var(--text-secondary)"
      } else if (diff > 0) {
        el.textContent = `in ${this.formatDuration(diff)}`
        el.style.color = "var(--text-secondary)"
        // Highlight if within 30 minutes
        if (diff <= 30) {
          el.style.color = "#f57c00"
          el.style.fontWeight = "700"
        }
      } else if (diff === 0) {
        el.textContent = "NOW"
        el.style.color = "var(--positive)"
        el.style.fontWeight = "700"
      } else {
        el.textContent = "passed"
        el.style.color = "var(--text-secondary)"
        el.style.opacity = "0.5"
      }
    })
  }

  // --- Helpers ---

  isSessionOpen(session, et) {
    const openMin = session.openH * 60 + session.openM
    const closeMin = session.closeH * 60 + session.closeM
    const now = et.totalMinutes

    if (session.crossesMidnight) {
      // Session spans midnight: open if now >= open OR now < close
      return now >= openMin || now < closeMin
    } else {
      return now >= openMin && now < closeMin
    }
  }

  minutesUntilClose(session, et) {
    const closeMin = session.closeH * 60 + session.closeM
    const now = et.totalMinutes

    if (session.crossesMidnight) {
      if (now >= session.openH * 60 + session.openM) {
        // Before midnight
        return (1440 - now) + closeMin
      } else {
        // After midnight
        return closeMin - now
      }
    } else {
      return closeMin - now
    }
  }

  minutesUntilOpen(session, et) {
    const openMin = session.openH * 60 + session.openM
    const now = et.totalMinutes

    let diff = openMin - now
    if (diff <= 0) diff += 1440
    return diff
  }

  sessionProgress(session, et) {
    const openMin = session.openH * 60 + session.openM
    const closeMin = session.closeH * 60 + session.closeM
    const now = et.totalMinutes

    let totalDuration, elapsed

    if (session.crossesMidnight) {
      totalDuration = (1440 - openMin) + closeMin
      if (now >= openMin) {
        elapsed = now - openMin
      } else {
        elapsed = (1440 - openMin) + now
      }
    } else {
      totalDuration = closeMin - openMin
      elapsed = now - openMin
    }

    return Math.min(100, Math.max(0, (elapsed / totalDuration) * 100))
  }

  formatDuration(totalMinutes) {
    if (totalMinutes < 0) totalMinutes += 1440
    const h = Math.floor(totalMinutes / 60)
    const m = Math.floor(totalMinutes % 60)
    if (h > 0) {
      return `${h}h ${String(m).padStart(2, "0")}m`
    }
    return `${m}m`
  }
}
