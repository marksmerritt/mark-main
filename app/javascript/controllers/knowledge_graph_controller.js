import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["canvas", "tooltip", "zoomLevel"]
  static values = {
    nodes: { type: Array, default: [] },
    edges: { type: Array, default: [] }
  }

  connect() {
    this.zoom = 1
    this.panX = 0
    this.panY = 0
    this.dragging = null
    this.panning = false
    this.panStart = null
    this.selectedNode = null
    this.simulation = null
    this.animFrame = null

    if (this.nodesValue.length > 0) {
      this.initGraph()
    }
  }

  disconnect() {
    if (this.animFrame) cancelAnimationFrame(this.animFrame)
  }

  initGraph() {
    const svg = this.canvasTarget
    const rect = svg.getBoundingClientRect()
    const w = rect.width || 800
    const h = rect.height || 600

    // Assign notebook colors
    const notebooks = [...new Set(this.nodesValue.map(n => n.notebook))]
    const palette = ["#1a73e8", "#0d904f", "#e8710a", "#d93025", "#9334e6", "#00bcd4", "#f9ab00", "#ec407a", "#5c6bc0", "#26a69a"]
    this.notebookColors = {}
    notebooks.forEach((nb, i) => this.notebookColors[nb] = palette[i % palette.length])

    // Initialize node positions
    this.nodes = this.nodesValue.map((n, i) => {
      const angle = (2 * Math.PI * i) / this.nodesValue.length
      const radius = Math.min(w, h) * 0.3
      return {
        ...n,
        x: w / 2 + radius * Math.cos(angle) + (Math.random() - 0.5) * 50,
        y: h / 2 + radius * Math.sin(angle) + (Math.random() - 0.5) * 50,
        vx: 0,
        vy: 0,
        radius: Math.max(5, Math.min(20, 5 + (n.connections || 0) * 2))
      }
    })

    this.nodeMap = {}
    this.nodes.forEach(n => this.nodeMap[n.id] = n)

    this.edges = this.edgesValue.filter(e =>
      this.nodeMap[e.source] && this.nodeMap[e.target]
    )

    this.centerX = w / 2
    this.centerY = h / 2

    // Run simulation
    this.simulate(150)
    this.render()
  }

  simulate(iterations) {
    const nodes = this.nodes
    const edges = this.edges

    for (let iter = 0; iter < iterations; iter++) {
      const alpha = 1 - iter / iterations
      const repulsion = 800 * alpha
      const attraction = 0.005 * alpha
      const centering = 0.01 * alpha

      // Repulsion between all pairs
      for (let i = 0; i < nodes.length; i++) {
        for (let j = i + 1; j < nodes.length; j++) {
          const dx = nodes[j].x - nodes[i].x
          const dy = nodes[j].y - nodes[i].y
          const dist = Math.sqrt(dx * dx + dy * dy) || 1
          const force = repulsion / (dist * dist)
          const fx = (dx / dist) * force
          const fy = (dy / dist) * force
          nodes[i].vx -= fx
          nodes[i].vy -= fy
          nodes[j].vx += fx
          nodes[j].vy += fy
        }
      }

      // Attraction along edges
      edges.forEach(e => {
        const source = this.nodeMap[e.source]
        const target = this.nodeMap[e.target]
        if (!source || !target) return
        const dx = target.x - source.x
        const dy = target.y - source.y
        const dist = Math.sqrt(dx * dx + dy * dy) || 1
        const force = dist * attraction
        source.vx += dx * force
        source.vy += dy * force
        target.vx -= dx * force
        target.vy -= dy * force
      })

      // Centering force
      nodes.forEach(n => {
        n.vx += (this.centerX - n.x) * centering
        n.vy += (this.centerY - n.y) * centering
      })

      // Apply velocities with damping
      nodes.forEach(n => {
        if (n === this.dragging) return
        n.x += n.vx * 0.5
        n.y += n.vy * 0.5
        n.vx *= 0.6
        n.vy *= 0.6
      })
    }
  }

  render() {
    const svg = this.canvasTarget
    // Clear existing content
    while (svg.firstChild) svg.removeChild(svg.firstChild)

    const g = document.createElementNS("http://www.w3.org/2000/svg", "g")
    g.setAttribute("transform", `translate(${this.panX},${this.panY}) scale(${this.zoom})`)
    this.mainGroup = g

    // Draw edges
    this.edges.forEach(e => {
      const source = this.nodeMap[e.source]
      const target = this.nodeMap[e.target]
      if (!source || !target) return

      const line = document.createElementNS("http://www.w3.org/2000/svg", "line")
      line.setAttribute("x1", source.x)
      line.setAttribute("y1", source.y)
      line.setAttribute("x2", target.x)
      line.setAttribute("y2", target.y)
      line.setAttribute("stroke", "var(--border)")
      line.setAttribute("stroke-width", "1")
      line.setAttribute("opacity", "0.4")
      g.appendChild(line)
    })

    // Draw nodes
    this.nodes.forEach(n => {
      const group = document.createElementNS("http://www.w3.org/2000/svg", "g")
      group.style.cursor = "pointer"
      group.dataset.nodeId = n.id

      const circle = document.createElementNS("http://www.w3.org/2000/svg", "circle")
      circle.setAttribute("cx", n.x)
      circle.setAttribute("cy", n.y)
      circle.setAttribute("r", n.radius)
      circle.setAttribute("fill", this.notebookColors[n.notebook] || "#1a73e8")
      circle.setAttribute("opacity", n.connections > 0 ? "0.8" : "0.3")
      circle.setAttribute("stroke", this.selectedNode === n.id ? "#fff" : "none")
      circle.setAttribute("stroke-width", "2")

      group.appendChild(circle)

      // Label for nodes with connections or larger nodes
      if (n.connections > 0 || n.radius > 8) {
        const text = document.createElementNS("http://www.w3.org/2000/svg", "text")
        text.setAttribute("x", n.x)
        text.setAttribute("y", n.y + n.radius + 12)
        text.setAttribute("text-anchor", "middle")
        text.setAttribute("fill", "var(--text)")
        text.setAttribute("font-size", `${Math.max(8, 10 - this.nodes.length * 0.02)}`)
        text.setAttribute("font-weight", n.connections >= 3 ? "600" : "400")
        text.textContent = n.title.length > 20 ? n.title.slice(0, 18) + "..." : n.title
        group.appendChild(text)
      }

      g.appendChild(group)
    })

    svg.appendChild(g)
  }

  handleMouseDown(e) {
    const svg = this.canvasTarget
    const point = this.svgPoint(e)

    // Check if clicking on a node
    const node = this.findNodeAt(point.x, point.y)
    if (node) {
      this.dragging = node
      this.selectedNode = node.id
      this.render()
      this.showTooltip(e, node)
      return
    }

    // Otherwise start panning
    this.panning = true
    this.panStart = { x: e.clientX - this.panX, y: e.clientY - this.panY }
  }

  handleMouseMove(e) {
    if (this.dragging) {
      const point = this.svgPoint(e)
      this.dragging.x = point.x
      this.dragging.y = point.y
      this.render()
      this.showTooltip(e, this.dragging)
    } else if (this.panning && this.panStart) {
      this.panX = e.clientX - this.panStart.x
      this.panY = e.clientY - this.panStart.y
      this.render()
    }
  }

  handleMouseUp(e) {
    if (this.dragging) {
      // Navigate to note on click (not drag)
      const node = this.dragging
      this.dragging = null
    }
    this.panning = false
    this.panStart = null
  }

  handleClick(e) {
    const point = this.svgPoint(e)
    const node = this.findNodeAt(point.x, point.y)
    if (node) {
      this.selectedNode = node.id
      this.showTooltip(e, node)
      this.highlightConnections(node)
    } else {
      this.selectedNode = null
      this.hideTooltip()
      this.render()
    }
  }

  handleDblClick(e) {
    const point = this.svgPoint(e)
    const node = this.findNodeAt(point.x, point.y)
    if (node) {
      window.location.href = `/notes/${node.id}`
    }
  }

  handleWheel(e) {
    e.preventDefault()
    const delta = e.deltaY > 0 ? 0.9 : 1.1
    this.zoom = Math.max(0.2, Math.min(3, this.zoom * delta))
    if (this.hasZoomLevelTarget) {
      this.zoomLevelTarget.textContent = `${Math.round(this.zoom * 100)}%`
    }
    this.render()
  }

  zoomIn() {
    this.zoom = Math.min(3, this.zoom * 1.2)
    if (this.hasZoomLevelTarget) this.zoomLevelTarget.textContent = `${Math.round(this.zoom * 100)}%`
    this.render()
  }

  zoomOut() {
    this.zoom = Math.max(0.2, this.zoom / 1.2)
    if (this.hasZoomLevelTarget) this.zoomLevelTarget.textContent = `${Math.round(this.zoom * 100)}%`
    this.render()
  }

  resetView() {
    this.zoom = 1
    this.panX = 0
    this.panY = 0
    if (this.hasZoomLevelTarget) this.zoomLevelTarget.textContent = "100%"
    this.render()
  }

  svgPoint(e) {
    const svg = this.canvasTarget
    const rect = svg.getBoundingClientRect()
    return {
      x: (e.clientX - rect.left - this.panX) / this.zoom,
      y: (e.clientY - rect.top - this.panY) / this.zoom
    }
  }

  findNodeAt(x, y) {
    for (const n of this.nodes) {
      const dx = x - n.x
      const dy = y - n.y
      if (dx * dx + dy * dy <= (n.radius + 5) * (n.radius + 5)) return n
    }
    return null
  }

  highlightConnections(node) {
    const connectedIds = new Set()
    connectedIds.add(node.id)
    this.edges.forEach(e => {
      if (e.source === node.id) connectedIds.add(e.target)
      if (e.target === node.id) connectedIds.add(e.source)
    })

    // Re-render with highlights
    const svg = this.canvasTarget
    while (svg.firstChild) svg.removeChild(svg.firstChild)

    const g = document.createElementNS("http://www.w3.org/2000/svg", "g")
    g.setAttribute("transform", `translate(${this.panX},${this.panY}) scale(${this.zoom})`)

    // Draw edges
    this.edges.forEach(e => {
      const source = this.nodeMap[e.source]
      const target = this.nodeMap[e.target]
      if (!source || !target) return
      const isConnected = e.source === node.id || e.target === node.id

      const line = document.createElementNS("http://www.w3.org/2000/svg", "line")
      line.setAttribute("x1", source.x)
      line.setAttribute("y1", source.y)
      line.setAttribute("x2", target.x)
      line.setAttribute("y2", target.y)
      line.setAttribute("stroke", isConnected ? this.notebookColors[node.notebook] || "#1a73e8" : "var(--border)")
      line.setAttribute("stroke-width", isConnected ? "2" : "1")
      line.setAttribute("opacity", isConnected ? "0.8" : "0.15")
      g.appendChild(line)
    })

    // Draw nodes
    this.nodes.forEach(n => {
      const isConnected = connectedIds.has(n.id)
      const circle = document.createElementNS("http://www.w3.org/2000/svg", "circle")
      circle.setAttribute("cx", n.x)
      circle.setAttribute("cy", n.y)
      circle.setAttribute("r", n.id === node.id ? n.radius * 1.3 : n.radius)
      circle.setAttribute("fill", this.notebookColors[n.notebook] || "#1a73e8")
      circle.setAttribute("opacity", isConnected ? "0.9" : "0.15")
      circle.setAttribute("stroke", n.id === node.id ? "#fff" : "none")
      circle.setAttribute("stroke-width", "2")
      circle.style.cursor = "pointer"
      g.appendChild(circle)

      if (isConnected) {
        const text = document.createElementNS("http://www.w3.org/2000/svg", "text")
        text.setAttribute("x", n.x)
        text.setAttribute("y", n.y + n.radius + 12)
        text.setAttribute("text-anchor", "middle")
        text.setAttribute("fill", "var(--text)")
        text.setAttribute("font-size", n.id === node.id ? "11" : "9")
        text.setAttribute("font-weight", n.id === node.id ? "700" : "400")
        text.textContent = n.title.length > 25 ? n.title.slice(0, 23) + "..." : n.title
        g.appendChild(text)
      }
    })

    svg.appendChild(g)
  }

  showTooltip(e, node) {
    if (!this.hasTooltipTarget) return
    const tip = this.tooltipTarget
    const connectedEdges = this.edges.filter(edge => edge.source === node.id || edge.target === node.id)
    const connectedNames = connectedEdges.map(edge => {
      const otherId = edge.source === node.id ? edge.target : edge.source
      return this.nodeMap[otherId]?.title || "Unknown"
    })

    tip.innerHTML = `
      <strong>${node.title}</strong>
      <div style="font-size: 0.6875rem; color: var(--text-secondary); margin-top: 2px;">
        ${node.notebook} &middot; ${node.word_count} words &middot; ${node.connections} links
      </div>
      ${node.tags.length > 0 ? `<div style="font-size: 0.625rem; margin-top: 3px;">${node.tags.join(", ")}</div>` : ""}
      ${connectedNames.length > 0 ? `<div style="font-size: 0.625rem; margin-top: 4px; border-top: 1px solid var(--border); padding-top: 3px;">Links: ${connectedNames.slice(0, 5).join(", ")}${connectedNames.length > 5 ? ` +${connectedNames.length - 5} more` : ""}</div>` : ""}
      <div style="font-size: 0.5625rem; color: var(--text-secondary); margin-top: 4px;">Double-click to open</div>
    `
    tip.style.display = "block"
    tip.style.left = `${e.clientX + 12}px`
    tip.style.top = `${e.clientY - 10}px`
  }

  hideTooltip() {
    if (this.hasTooltipTarget) this.tooltipTarget.style.display = "none"
  }
}
