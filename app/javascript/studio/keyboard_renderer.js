export class KeyboardRenderer {
  static buildBed(containerEl, notesList, onKeyTrigger) {
    if (!containerEl) return
    containerEl.innerHTML = ""
    const whites = notesList.filter(n => !n.isBlack)
    const wPct = 100 / whites.length

    whites.forEach((n, i) => {
      const el = document.createElement("div")
      el.className = "w-key"
      el.dataset.note = n.id
      el.style.left = `${i * wPct}%`
      el.style.width = `${wPct}%`

      const lbl = document.createElement("span")
      lbl.className = "key-lbl"
      lbl.textContent = n.id === "C4" ? "C4" : n.id.replace(/\d/, "")
      el.appendChild(lbl)

      el.addEventListener("pointerdown", () => onKeyTrigger(n.id))
      containerEl.appendChild(el)
    })

    notesList.forEach(n => {
      if (!n.isBlack) return
      const prevWhiteIdx = whites.findIndex(w => w.midi === n.midi - 1)
      if (prevWhiteIdx === -1) return
      const el = document.createElement("div")
      el.className = "b-key"
      el.dataset.note = n.id
      el.style.width = `${wPct * 0.64}%`
      el.style.left = `${(prevWhiteIdx + 0.68) * wPct}%`

      const lbl = document.createElement("span")
      lbl.className = "key-lbl"
      lbl.textContent = n.id.replace(/\d/, "")
      el.appendChild(lbl)

      el.addEventListener("pointerdown", e => {
        e.stopPropagation()
        onKeyTrigger(n.id)
      })
      containerEl.appendChild(el)
    })
  }

  static updateHighlights({ pianoBedEl, voiceBedEl, step, state }) {
    if (!step || !pianoBedEl) return
    const lv = step.levels[state.level] || step.levels.faithful
    const focusT = state.frozenTick >= 0 ? state.frozenTick : state.activeTick

    pianoBedEl.querySelectorAll(".w-key, .b-key").forEach(k => {
      k.classList.remove("lh-target", "rh-target", "now-playing")
      k.querySelectorAll(".f-dot, .ord-tag").forEach(d => d.remove())
    })

    const applyHand = (events, cls) => {
      if ((cls === "lh" && state.handMode === "rh") || (cls === "rh" && state.handMode === "lh")) return
      const isArpeggio = events.length >= 4 && new Set(events.map(e => e.notes[0])).size >= 3
      events.forEach((ev, idx) => {
        const isNow = focusT >= 0 && focusT >= ev.tick && focusT < ev.tick + ev.dur
        ev.notes.forEach((nId, i) => {
          const keyEl = pianoBedEl.querySelector(`[data-note="${nId}"]`)
          if (!keyEl) return
          keyEl.classList.add(`${cls}-target`)
          if (isNow) keyEl.classList.add("now-playing")
          if (!keyEl.querySelector(`.f-dot.${cls}`) && ev.fingers[i]) {
            const dot = document.createElement("div")
            dot.className = `f-dot ${cls}`
            dot.textContent = ev.fingers[i]
            if (cls === "rh") dot.style.right = "3px"
            keyEl.appendChild(dot)
          }
          if (isArpeggio && idx < 6 && !keyEl.querySelector(".ord-tag")) {
            const tag = document.createElement("div")
            tag.className = "ord-tag"
            tag.textContent = `${idx + 1}º`
            keyEl.appendChild(tag)
          }
        })
      })
    }

    applyHand(lv.lh, "lh")
    applyHand(lv.rh, "rh")

    if (voiceBedEl) {
      voiceBedEl.querySelectorAll(".w-key, .b-key").forEach(k => {
        k.classList.remove("vox-target", "now-playing")
        k.querySelectorAll(".f-dot").forEach(d => d.remove())
      })
      if (state.showVoicePanel && step.voice) {
        step.voice.forEach(v => {
          const keyEl = voiceBedEl.querySelector(`[data-note="${v.note}"]`)
          if (!keyEl) return
          keyEl.classList.add("vox-target")
          if (focusT >= 0 && focusT >= v.tick && focusT < v.tick + v.dur) {
            keyEl.classList.add("now-playing")
          }
        })
      }
    }
  }
}
