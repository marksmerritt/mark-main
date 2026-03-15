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
    this.fields = [
      { key: "transaction_date", label: "Date", required: true },
      { key: "amount", label: "Amount", required: true },
      { key: "description", label: "Description", required: false },
      { key: "merchant", label: "Merchant", required: false },
      { key: "transaction_type", label: "Type (income/expense)", required: false },
      { key: "status", label: "Status", required: false },
      { key: "notes", label: "Notes", required: false }
    ]
    this.autoMapAliases = {
      transaction_date: ["date", "transaction date", "transaction_date", "trans date", "posting date", "posted", "posted date"],
      amount: ["amount", "total", "sum", "value", "debit", "credit", "price"],
      description: ["description", "desc", "memo", "details", "narrative", "transaction", "transaction description"],
      merchant: ["merchant", "payee", "vendor", "name", "store", "company", "merchant name"],
      transaction_type: ["type", "transaction type", "transaction_type", "category type", "kind"],
      status: ["status", "state", "cleared"],
      notes: ["notes", "note", "comment", "comments", "category"]
    }
  }

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

    this.fields.forEach(field => {
      const tr = document.createElement("tr")

      const tdField = document.createElement("td")
      tdField.innerHTML = `<strong>${field.label}</strong>${field.required ? ' <span style="color: var(--negative);">*</span>' : ''}`
      tr.appendChild(tdField)

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

      const tdSample = document.createElement("td")
      tdSample.className = "text-muted"
      tdSample.style.fontSize = "0.8125rem"
      const colIdx = this.mapping[field.key]
      if (colIdx !== undefined) {
        const samples = this.rows.slice(0, 3).map(r => r[colIdx] || "").filter(Boolean)
        tdSample.textContent = samples.join(", ")
      } else {
        tdSample.textContent = "\u2014"
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
    this.fields.forEach(field => {
      const td = this.mappingBodyTarget.querySelector(`[data-sample-for="${field.key}"]`)
      if (!td) return
      const colIdx = this.mapping[field.key]
      if (colIdx !== undefined) {
        const samples = this.rows.slice(0, 3).map(r => r[colIdx] || "").filter(Boolean)
        td.textContent = samples.join(", ")
      } else {
        td.textContent = "\u2014"
      }
    })
  }

  goToPreview() {
    const missing = this.fields.filter(f => f.required && this.mapping[f.key] === undefined)
    if (missing.length > 0) {
      alert(`Please map required fields: ${missing.map(f => f.label).join(", ")}`)
      return
    }
    this.buildPreview()
    this.showStep(3)
  }

  buildPreview() {
    const preview = this.rows.map((row, idx) => {
      const txn = {}
      const errors = []

      for (const field of this.fields) {
        const colIdx = this.mapping[field.key]
        if (colIdx === undefined) continue
        const val = (row[colIdx] || "").trim()
        if (field.required && !val) {
          errors.push(`Missing ${field.label}`)
        }
        txn[field.key] = val
      }

      // Validate amount
      if (txn.amount) {
        const cleaned = txn.amount.replace(/[$,\s]/g, "")
        if (isNaN(parseFloat(cleaned))) {
          errors.push("Invalid amount")
        }
      }

      // Validate date
      if (txn.transaction_date) {
        const d = new Date(txn.transaction_date)
        if (isNaN(d.getTime())) {
          errors.push("Invalid date")
        }
      }

      return { txn, errors, rowNum: idx + 2 }
    })

    this.preview = preview
    const valid = preview.filter(p => p.errors.length === 0)
    const invalid = preview.filter(p => p.errors.length > 0)

    this.previewCountTarget.textContent = preview.length
    this.validCountTarget.textContent = valid.length
    this.errorCountTarget.textContent = invalid.length

    if (invalid.length > 0) {
      this.errorListTarget.classList.remove("hidden")
      this.errorListTarget.innerHTML = invalid.slice(0, 10).map(p =>
        `<div style="padding: 0.375rem 0.5rem; border-bottom: 1px solid var(--border); font-size: 0.8125rem;">
          <strong>Row ${p.rowNum}:</strong> ${p.errors.join(", ")}
          <span class="text-muted" style="margin-left: 0.5rem;">${p.txn.description || p.txn.merchant || "?"}</span>
        </div>`
      ).join("") + (invalid.length > 10 ? `<div style="padding: 0.375rem 0.5rem; font-size: 0.8125rem; color: var(--text-secondary);">...and ${invalid.length - 10} more</div>` : "")
    } else {
      this.errorListTarget.classList.add("hidden")
    }

    const tbody = this.previewBodyTarget
    tbody.innerHTML = ""
    preview.slice(0, 20).forEach(p => {
      const tr = document.createElement("tr")
      if (p.errors.length > 0) tr.style.opacity = "0.5"
      const displayFields = ["transaction_date", "amount", "description", "merchant", "transaction_type"]
      displayFields.forEach(f => {
        const td = document.createElement("td")
        td.textContent = p.txn[f] || "\u2014"
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
      td.colSpan = 6
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
    const fieldOrder = ["transaction_date", "amount", "description", "merchant", "transaction_type", "status", "notes"]
    const headerRow = fieldOrder.map(f => {
      const field = this.fields.find(tf => tf.key === f)
      return field ? field.label : f
    })

    const dataRows = this.rows.map(row => {
      return fieldOrder.map(f => {
        const colIdx = this.mapping[f]
        if (colIdx === undefined) return ""
        const val = (row[colIdx] || "").trim()
        if (val.includes(",") || val.includes('"') || val.includes("\n")) {
          return `"${val.replace(/"/g, '""')}"`
        }
        return val
      })
    })

    const csvContent = [headerRow.join(","), ...dataRows.map(r => r.join(","))].join("\n")

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

    this.element.querySelectorAll("[data-step-indicator]").forEach(el => {
      const step = parseInt(el.dataset.stepIndicator)
      el.classList.toggle("active", step === n)
      el.classList.toggle("completed", step < n)
    })
  }
}
