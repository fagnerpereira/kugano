import { NOTE_MAP, displayCipher } from "./note_table"

const STEPS_FROM_E4 = { 0: 0, 1: 0, 2: 1, 3: 1, 4: 2, 5: 3, 6: 3, 7: 4, 8: 4, 9: 5, 10: 5, 11: 6 }
const STEPS_FROM_C = { 0: 0, 1: 0, 2: 1, 3: 1, 4: 2, 5: 3, 6: 3, 7: 4, 8: 4, 9: 5, 10: 5, 11: 6 }

export class SheetRenderer {
  static midiToTrebleY(midi) {
    const oct = Math.floor(midi / 12) - 1
    const deg = (oct - 4) * 7 + STEPS_FROM_E4[midi % 12] - 2
    return 118 - deg * 6.5
  }

  static midiToBassY(midi) {
    const oct = Math.floor(midi / 12) - 1
    const deg = (oct - 2) * 7 + STEPS_FROM_C[midi % 12] - 4
    return 248 - deg * 6.5
  }

  static render({ svgEl, steps, state, ticksPerMeasure = 16, onSliceClick }) {
    if (!svgEl) return
    svgEl.innerHTML = ""
    const cur = steps[state.stepIndex]
    if (!cur) return

    if (state.zoomOneMeasure || state.stepIndex >= steps.length - 1) {
      this.drawSingleMeasure(svgEl, cur, 14, 932, true, state, ticksPerMeasure, onSliceClick)
    } else {
      this.drawSingleMeasure(svgEl, cur, 14, 460, true, state, ticksPerMeasure, onSliceClick)
      this.drawSingleMeasure(svgEl, steps[state.stepIndex + 1], 486, 460, false, state, ticksPerMeasure, onSliceClick)
    }
  }

  static drawSingleMeasure(svg, step, x0, mWidth, isCurrent, state, ticksPerMeasure, onSliceClick) {
    const dark = document.documentElement.classList.contains("dark")
    const lineCol = dark ? "#475569" : "#94a3b8"
    const inkCol = dark ? "#f8fafc" : "#0f172a"
    const mutedCol = dark ? "#cbd5e1" : "#64748b"
    const lhCol = dark ? "#93c5fd" : "#1d4ed8"
    const rhCol = dark ? "#6ee7b7" : "#047857"
    const voxCol = dark ? "#fcd34d" : "#b45309"
    const haloCol = dark ? "#0f172a" : "#ffffff"

    const lv = step.levels[state.level] || step.levels.faithful
    const NS = "http://www.w3.org/2000/svg"
    const addEl = (tag, attrs) => {
      const el = document.createElementNS(NS, tag)
      Object.entries(attrs).forEach(([k, v]) => el.setAttribute(k, v))
      svg.appendChild(el)
      return el
    }

    // Linhas das 2 pautas (Clave de Sol e Clave de Fá)
    for (let i = 0; i < 5; i++) {
      addEl("line", { x1: x0, y1: 66 + i * 13, x2: x0 + mWidth, y2: 66 + i * 13, stroke: lineCol, "stroke-width": "1.2" })
      addEl("line", { x1: x0, y1: 196 + i * 13, x2: x0 + mWidth, y2: 196 + i * 13, stroke: lineCol, "stroke-width": "1.2" })
    }
    // Barras verticais de compasso
    addEl("line", { x1: x0, y1: 66, x2: x0, y2: 248, stroke: inkCol, "stroke-width": "2" })
    addEl("line", { x1: x0 + mWidth, y1: 66, x2: x0 + mWidth, y2: 248, stroke: inkCol, "stroke-width": "2" })

    // Título do compasso + acorde
    addEl("text", { x: x0 + 14, y: 34, fill: inkCol, "font-size": "16", "font-weight": "800", "font-family": "JetBrains Mono, monospace" }).textContent = `${step.tag} • ${lv.chord}`
    if (lv.pedal) {
      addEl("text", { x: x0 + mWidth - 48, y: 278, fill: mutedCol, "font-size": "12", "font-weight": "700", "font-family": "JetBrains Mono, monospace" }).textContent = "Ped."
    }

    // Claves na margem esquerda
    addEl("text", { x: x0 + 10, y: 112, fill: inkCol, "font-size": "44", "font-family": "serif" }).textContent = "𝄞"
    addEl("text", { x: x0 + 10, y: 238, fill: inkCol, "font-size": "38", "font-family": "serif" }).textContent = "𝄢"

    const padL = 56
    const usableW = mWidth - padL - 20
    const totalTicks = Math.max(4, ticksPerMeasure || 16)
    const tickToX = t => x0 + padL + (t / totalTicks) * usableW

    // Dynamic beat divisions based on ticksPerMeasure (supports 4/4, 3/4, 6/8, 2/4, etc.)
    const numBeats = Math.max(1, Math.round(totalTicks / 4))
    for (let b = 0; b < numBeats; b++) {
      const bx = tickToX(b * 4)
      if (b > 0) {
        addEl("line", { x1: bx, y1: 54, x2: bx, y2: 256, stroke: lineCol, "stroke-width": "1", "stroke-dasharray": "4 4", opacity: "0.55" })
      }
      addEl("text", { x: bx + usableW / (numBeats * 2), y: 50, fill: mutedCol, "font-size": "11", "font-weight": "700", "text-anchor": "middle", "font-family": "JetBrains Mono, monospace" }).textContent = `T${b + 1}`
    }

    // Playhead (linha vertical azul no tempo ativo)
    const focusT = isCurrent ? (state.frozenTick >= 0 ? state.frozenTick : state.activeTick) : -1
    if (focusT >= 0) {
      const px = tickToX(Math.min(focusT, totalTicks - 1))
      addEl("rect", { x: px - 6, y: 52, width: usableW / Math.max(4, numBeats * 2), height: 206, fill: "#3b82f6", opacity: "0.14", rx: "6" })
      addEl("line", { x1: px, y1: 52, x2: px, y2: 258, stroke: "#3b82f6", "stroke-width": "2.5" })
    }

    const drawEvents = (events, isTreble, color, isVox = false) => {
      ;(events || []).forEach(ev => {
        const cx = tickToX(ev.tick || 0) + 12
        const notes = isVox ? [ev.note] : (ev.notes || [])
        const fingers = isVox ? [] : (ev.fingers || [])
        notes.forEach((nId, idx) => {
          const nObj = NOTE_MAP[nId]
          if (!nObj) return
          const cy = isTreble ? this.midiToTrebleY(nObj.midi) : this.midiToBassY(nObj.midi)

          // Linhas suplementares
          if (isTreble && nObj.midi <= 60) {
            addEl("line", { x1: cx - 11, y1: 131, x2: cx + 11, y2: 131, stroke: inkCol, "stroke-width": "1.3" })
          }
          if (!isTreble && nObj.midi <= 40) {
            addEl("line", { x1: cx - 11, y1: 261, x2: cx + 11, y2: 261, stroke: inkCol, "stroke-width": "1.3" })
          }

          if (isVox) {
            addEl("polygon", { points: `${cx},${cy - 6} ${cx + 6},${cy} ${cx},${cy + 6} ${cx - 6},${cy}`, fill: color })
          } else {
            addEl("ellipse", {
              cx, cy, rx: "6.5", ry: "4.8",
              fill: ev.dur >= 8 ? haloCol : color,
              stroke: color,
              "stroke-width": "2",
              transform: `rotate(-18 ${cx} ${cy})`
            })
          }

          // Rótulo de cifra + dedo
          if (state.showCiphers && !isVox) {
            const fTxt = fingers[idx] ? `(${fingers[idx]})` : ""
            const lblStr = `${displayCipher(nId, lv.chord)}${fTxt}`
            const lx = cx + 10
            const ly = cy + 4
            addEl("rect", { x: lx - 2, y: ly - 10, width: lblStr.length * 6.8 + 4, height: 13, fill: haloCol, opacity: "0.88", rx: "3" })
            addEl("text", { x: lx, y: ly, fill: color, "font-size": "11", "font-weight": "800", "font-family": "JetBrains Mono, monospace" }).textContent = lblStr
          }
        })
      })
    }

    if (state.handMode !== "lh") drawEvents(lv.rh, true, rhCol, false)
    if (state.handMode !== "rh") drawEvents(lv.lh, false, lhCol, false)
    if (state.showVoicePanel && step.voice?.length) drawEvents(step.voice, true, voxCol, true)

    // Zonas clicáveis por colcheia para congelar/ouvir aquele instante
    const numSlices = Math.max(2, Math.floor(totalTicks / 2))
    for (let e = 0; e < numSlices; e++) {
      const hit = addEl("rect", {
        x: tickToX(e * 2), y: 52, width: usableW / numSlices, height: 206,
        fill: "transparent", style: "cursor: pointer;"
      })
      hit.addEventListener("click", () => {
        if (onSliceClick) onSliceClick(step, isCurrent, e * 2)
      })
    }
  }
}
