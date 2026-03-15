import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dropZone", "fileInput", "step1", "step2", "step3",
                     "fileName", "rowCount", "headerCount",
                     "mappingBody", "previewBody", "previewCount",
                     "validCount", "errorCount", "errorList",
                     "submitBtn", "hiddenFile"]

  static values = { step: { type: Number, default: 1 } }

  connect() {
    this.csvData = null
    this.headers = []
    this.rows = []
    this.mapping = {}
    this.tradeFields = [
      { key: "symbol", label: "Symbol", required: true },
      { key: "side", label: "Side", required: true },
      { key: "quantity", label: "Quantity", required: true },
      { key: "entry_price", label: "Entry Price", required: true },
      { key: "exit_price", label: "Exit Price", required: false },
      { key: "entry_time", label: "Entry Time", required: false },
      { key: "exit_time", label: "Exit Time", required: false },
      { key: "commissions", label: "Commissions", required: false },
      { key: "fees", label: "Fees", required: false },
      { key: "notes", label: "Notes", required: false },
      { key: "asset_class", label: "Asset Class", required: false },
      { key: "setup", label: "Setup", required: false },
      { key: "stop_loss", label: "Stop Loss", required: false },
      { key: "take_profit", label: "Take Profit", required: false }
    ]
    this.autoMapAliases = {
      symbol: ["symbol", "ticker", "sym", "instrument", "stock"],
      side: ["side", "direction", "type", "action", "buy/sell", "b/s"],
      quantity: ["quantity", "qty", "shares", "contracts", "size", "volume", "lots"],
      entry_price: ["entry price", "entry", "open price", "open", "buy price", "entry_price", "entryprice"],
      exit_price: ["exit price", "exit", "close price", "close", "sell price", "exit_price", "exitprice"],
      entry_time: ["entry time", "entry date", "open time", "open date", "date", "entry_time", "entrytime", "trade date"],
      exit_time: ["exit time", "exit date", "close time", "close date", "exit_time", "exittime"],
      commissions: ["commissions", "commission", "comm"],
      fees: ["fees", "fee", "charges"],
      notes: ["notes", "note", "comment", "comments", "description"],
      asset_class: ["asset class", "asset_class", "assetclass", "class", "market"],
      setup: ["setup", "strategy", "pattern"],
      stop_loss: ["stop loss", "stop", "sl", "stop_loss", "stoploss"],
      take_profit: ["take profit", "target", "tp", "take_profit", "takeprofit"]
    }
  }

  // Drag & drop handlers
  dragOver(e) {
    e.preventDefault()
    e.stopPropagation()
    this.dropZoneTarget.classList.add("drag-over")
  }

  dragLeave(e) {
    e.preventDefault()
    e.stopPropagation()
    this.dropZoneTarget.classList.remove("drag-over")
  }

  drop(e) {
    e.preventDefault()
    e.stopPropagation()
    this.dropZoneTarget.classList.remove("drag-over")
    const file = e.dataTransfer.files[0]
    if (file) this.processFile(file)
  }

  selectFile() {
    this.fileInputTarget.click()
  }

  fileSelected(e) {
    const file = e.target.files[0]
    if (file) this.processFile(file)
  }

  processFile(file) {
    if (!file.name.endsWith(".csv")) {
      alert("Please select a CSV file.")
      return
    }

    this.file = file
    const reader = new FileReader()
    reader.onload = (e) => {
      this.csvData = e.target.result
      this.parseCSV()
      this.showStep(2)
    }
    reader.readAsText(file)
  }

  parseCSV() {
    const lines = this.csvData.split(/\r?\n/).filter(l => l.trim())
    if (lines.length < 2) {
      alert("CSV file must have a header row and at least one data row.")
      return
    }

    this.headers = this.parseCSVLine(lines[0])
    this.rows = lines.slice(1).map(l => this.parseCSVLine(l)).filter(r => r.some(c => c.trim()))

    this.fileNameTarget.textContent = this.file.name
    this.rowCountTarget.textContent = this.rows.length
    this.headerCountTarget.textContent = this.headers.length

    this.autoMap()
    this.renderMapping()
  }

  parseCSVLine(line) {
    const result = []
    let current = ""
    let inQuotes = false

    for (let i = 0; i < line.length; i++) {
      const ch = line[i]
      if (inQuotes) {
        if (ch === '"') {
          if (i + 1 < line.length && line[i + 1] === '"') {
            current += '"'
            i++
          } else {
            inQuotes = false
          }
        } else {
          current += ch
        }
      } else {
        if (ch === '"') {
          inQuotes = true
        } else if (ch === ',') {
          result.push(current.trim())
          current = ""
        } else {
          current += ch
        }
      }
    }
    result.push(current.trim())
    return result
  }

  autoMap() {
    this.mapping = {}
    this.headers.forEach((header, idx) => {
      const normalized = header.toLowerCase().trim()
      for (const [field, aliases] of Object.entries(this.autoMapAliases)) {
        if (aliases.includes(normalized)) {
          this.mapping[field] = idx
          break
        }
      }
    })
  }

  renderMapping() {
    const tbody = this.mappingBodyTarget
    tbody.innerHTML = ""

    this.tradeFields.forEach(field => {
      const tr = document.createElement("tr")

      // Field name
      const tdField = document.createElement("td")
      tdField.innerHTML = `<strong>${field.label}</strong>${field.required ? ' <span style="color: var(--negative);">*</span>' : ''}`
      tr.appendChild(tdField)

      // CSV column select
      const tdSelect = document.createElement("td")
      const select = document.createElement("select")
      select.className = "form-control"
      select.dataset.field = field.key
      select.addEventListener("change", () => this.mappingChanged())

      const skipOpt = document.createElement("option")
      skipOpt.value = ""
      skipOpt.textContent = "-- Skip --"
      select.appendChild(skipOpt)

      this.headers.forEach((h, i) => {
        const opt = document.createElement("option")
        opt.value = i
        opt.textContent = h
        if (this.mapping[field.key] === i) opt.selected = true
        select.appendChild(opt)
      })
      tdSelect.appendChild(select)
      tr.appendChild(tdSelect)

      // Sample data
      const tdSample = document.createElement("td")
      tdSample.className = "text-muted"
      tdSample.style.fontSize = "0.8125rem"
      const colIdx = this.mapping[field.key]
      if (colIdx !== undefined) {
        const samples = this.rows.slice(0, 3).map(r => r[colIdx] || "").filter(Boolean)
        tdSample.textContent = samples.join(", ")
      } else {
        tdSample.textContent = "—"
      }
      tdSample.dataset.sampleFor = field.key
      tr.appendChild(tdSample)

      tbody.appendChild(tr)
    })
  }

  mappingChanged() {
    const selects = this.mappingBodyTarget.querySelectorAll("select")
    this.mapping = {}
    selects.forEach(sel => {
      if (sel.value !== "") {
        this.mapping[sel.dataset.field] = parseInt(sel.value)
      }
    })
    // Update sample data
    this.tradeFields.forEach(field => {
      const td = this.mappingBodyTarget.querySelector(`[data-sample-for="${field.key}"]`)
      if (!td) return
      const colIdx = this.mapping[field.key]
      if (colIdx !== undefined) {
        const samples = this.rows.slice(0, 3).map(r => r[colIdx] || "").filter(Boolean)
        td.textContent = samples.join(", ")
      } else {
        td.textContent = "—"
      }
    })
  }

  goToPreview() {
    // Validate required fields
    const missing = this.tradeFields.filter(f => f.required && this.mapping[f.key] === undefined)
    if (missing.length > 0) {
      alert(`Please map required fields: ${missing.map(f => f.label).join(", ")}`)
      return
    }
    this.buildPreview()
    this.showStep(3)
  }

  buildPreview() {
    const preview = this.rows.map((row, idx) => {
      const trade = {}
      const errors = []

      for (const field of this.tradeFields) {
        const colIdx = this.mapping[field.key]
        if (colIdx === undefined) continue
        const val = (row[colIdx] || "").trim()
        if (field.required && !val) {
          errors.push(`Missing ${field.label}`)
        }
        trade[field.key] = val
      }

      // Validate values
      if (trade.quantity && isNaN(parseFloat(trade.quantity))) {
        errors.push("Invalid quantity")
      }
      if (trade.entry_price && isNaN(parseFloat(trade.entry_price))) {
        errors.push("Invalid entry price")
      }
      if (trade.side) {
        const s = trade.side.toLowerCase()
        if (!["long", "short", "buy", "sell"].includes(s)) {
          errors.push(`Unknown side: ${trade.side}`)
        }
      }

      return { trade, errors, rowNum: idx + 2 }
    })

    this.preview = preview
    const valid = preview.filter(p => p.errors.length === 0)
    const invalid = preview.filter(p => p.errors.length > 0)

    this.previewCountTarget.textContent = preview.length
    this.validCountTarget.textContent = valid.length
    this.errorCountTarget.textContent = invalid.length

    // Show errors
    if (invalid.length > 0) {
      this.errorListTarget.classList.remove("hidden")
      this.errorListTarget.innerHTML = invalid.slice(0, 10).map(p =>
        `<div style="padding: 0.375rem 0.5rem; border-bottom: 1px solid var(--border); font-size: 0.8125rem;">
          <strong>Row ${p.rowNum}:</strong> ${p.errors.join(", ")}
          <span class="text-muted" style="margin-left: 0.5rem;">${p.trade.symbol || "?"} ${p.trade.side || ""}</span>
        </div>`
      ).join("") + (invalid.length > 10 ? `<div style="padding: 0.375rem 0.5rem; font-size: 0.8125rem; color: var(--text-secondary);">...and ${invalid.length - 10} more</div>` : "")
    } else {
      this.errorListTarget.classList.add("hidden")
    }

    // Preview table
    const tbody = this.previewBodyTarget
    tbody.innerHTML = ""
    preview.slice(0, 20).forEach(p => {
      const tr = document.createElement("tr")
      if (p.errors.length > 0) tr.style.opacity = "0.5"
      const fields = ["symbol", "side", "quantity", "entry_price", "exit_price", "entry_time", "commissions"]
      fields.forEach(f => {
        const td = document.createElement("td")
        td.textContent = p.trade[f] || "—"
        td.style.fontSize = "0.8125rem"
        tr.appendChild(td)
      })
      const tdStatus = document.createElement("td")
      if (p.errors.length === 0) {
        tdStatus.innerHTML = '<span style="color: var(--positive); font-size: 0.8125rem;">Ready</span>'
      } else {
        tdStatus.innerHTML = `<span style="color: var(--negative); font-size: 0.8125rem;" title="${p.errors.join(', ')}">${p.errors.length} error(s)</span>`
      }
      tr.appendChild(tdStatus)
      tbody.appendChild(tr)
    })

    if (preview.length > 20) {
      const tr = document.createElement("tr")
      const td = document.createElement("td")
      td.colSpan = 8
      td.style.textAlign = "center"
      td.style.color = "var(--text-secondary)"
      td.style.fontSize = "0.8125rem"
      td.textContent = `...and ${preview.length - 20} more rows`
      tr.appendChild(td)
      tbody.appendChild(tr)
    }

    this.submitBtnTarget.disabled = valid.length === 0
  }

  backToMapping() {
    this.showStep(2)
  }

  backToUpload() {
    this.showStep(1)
  }

  submitImport() {
    // Build a remapped CSV with standard headers the API expects
    const fieldOrder = ["symbol", "side", "quantity", "entry_price", "exit_price",
                        "entry_time", "exit_time", "commissions", "fees", "notes",
                        "asset_class", "setup", "stop_loss", "take_profit"]
    const headerRow = fieldOrder.map(f => {
      const field = this.tradeFields.find(tf => tf.key === f)
      return field ? field.label : f
    })

    const dataRows = this.rows.map(row => {
      return fieldOrder.map(f => {
        const colIdx = this.mapping[f]
        if (colIdx === undefined) return ""
        const val = (row[colIdx] || "").trim()
        // Escape CSV values
        if (val.includes(",") || val.includes('"') || val.includes("\n")) {
          return `"${val.replace(/"/g, '""')}"`
        }
        return val
      })
    })

    const csvContent = [headerRow.join(","), ...dataRows.map(r => r.join(","))].join("\n")

    // Create a file from the remapped CSV and submit
    const blob = new Blob([csvContent], { type: "text/csv" })
    const file = new File([blob], this.file.name, { type: "text/csv" })

    const dt = new DataTransfer()
    dt.items.add(file)
    this.hiddenFileTarget.files = dt.files

    this.submitBtnTarget.disabled = true
    this.submitBtnTarget.textContent = "Importing..."

    this.element.querySelector("form").requestSubmit()
  }

  showStep(n) {
    this.stepValue = n
    this.step1Target.classList.toggle("hidden", n !== 1)
    this.step2Target.classList.toggle("hidden", n !== 2)
    this.step3Target.classList.toggle("hidden", n !== 3)

    // Update step indicators
    this.element.querySelectorAll("[data-step-indicator]").forEach(el => {
      const step = parseInt(el.dataset.stepIndicator)
      el.classList.toggle("active", step === n)
      el.classList.toggle("completed", step < n)
    })
  }
}
