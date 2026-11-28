import { Controller } from "@hotwired/stimulus"
import { PIANO_NOTES, VOICE_NOTES } from "../studio/note_table"
import { AudioEngine } from "../studio/audio_engine"
import { KeyboardRenderer } from "../studio/keyboard_renderer"
import { SheetRenderer } from "../studio/sheet_renderer"

export default class extends Controller {
  static values = {
    initialSong: { type: String, default: "todo-no" },
    importingSong: { type: String, default: "" }
  }

  connect() {
    const rawCatalog = document.getElementById("piano-catalog-data")?.textContent
    this.songs = rawCatalog ? JSON.parse(rawCatalog) : {}
    this.audio = new AudioEngine()

    this.state = {
      songId: this.initialSongValue || "todo-no",
      level: "faithful",
      handMode: "both",
      bpm: 76,
      ticksPerMeasure: 16,
      stepIndex: 0,
      activeTick: -1,
      frozenTick: -1,
      zoomOneMeasure: true,
      showCiphers: true,
      showVoicePanel: false,
      isPlaying: false,
      playMode: "step",
      timer: null
    }

    this.sections = []
    this.steps = []

    this.pianoBedEl = document.getElementById("piano-bed")
    this.voiceBedEl = document.getElementById("voice-bed")
    this.sheetSvgEl = document.getElementById("sheet-svg")

    KeyboardRenderer.buildBed(this.pianoBedEl, PIANO_NOTES, noteId => {
      this.audio.playTone(noteId, 0.5, 0.7, false)
    })
    KeyboardRenderer.buildBed(this.voiceBedEl, VOICE_NOTES, noteId => {
      const timbre = document.getElementById("voice-timbre-select")?.value || "rhodes"
      this.audio.playTone(noteId, 0.5, 0.7, true, timbre)
    })

    this.updateHandButtons()

    if (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) {
      document.documentElement.classList.add("dark")
    }

    this.bindUIEvents()
    this.applySongPack(this.state.songId)
    this.audio.initSoundfont(document.getElementById("audio-engine-badge"))
    if (this.importingSongValue) {
      this.pollImportingSong(this.importingSongValue)
    }
  }

  disconnect() {
    this.stopPlay(true)
    this.cleanupMicRecorder()
    if (this.importPollTimer) clearInterval(this.importPollTimer)
    if (this.keyHandler) {
      document.removeEventListener("keydown", this.keyHandler)
    }
  }

  renderSheetSVG() {
    SheetRenderer.render({
      svgEl: this.sheetSvgEl,
      steps: this.steps,
      state: this.state,
      ticksPerMeasure: this.state.ticksPerMeasure,
      onSliceClick: (step, isCurrent, tick) => {
        if (!isCurrent) {
          const foundIdx = this.steps.indexOf(step)
          this.state.stepIndex = foundIdx >= 0 ? foundIdx : Math.max(0, (step.id || 1) - 1)
        }
        this.state.frozenTick = tick
        this.triggerTickAudio(this.steps[this.state.stepIndex], this.state.frozenTick)
        this.renderMeasureView()
      }
    })
  }

  renderMeasureView() {
    if (!this.steps.length) return
    this.state.stepIndex = Math.max(0, Math.min(this.state.stepIndex, this.steps.length - 1))
    const step = this.steps[this.state.stepIndex]
    if (!step || !step.levels) return
    const lv = step.levels[this.state.level] || step.levels.faithful || step.levels.original || step.levels.easy
    if (!lv) return

    document.getElementById("step-counter").textContent = `Compasso ${step.id} / ${this.steps.length}`
    document.getElementById("chord-badge").textContent = lv.chord
    document.getElementById("measure-badge").textContent = step.tag
    document.getElementById("step-title").textContent = step.title
    document.getElementById("step-lyric").textContent = step.lyric
    document.getElementById("step-tip").textContent = lv.tip
    document.getElementById("step-select").value = this.state.stepIndex

    document.getElementById("btn-prev").disabled = this.state.stepIndex === 0
    document.getElementById("btn-next").disabled = this.state.stepIndex === this.steps.length - 1
    document.getElementById("btn-unfreeze").classList.toggle("hidden", this.state.frozenTick < 0)

    document.querySelectorAll(".sec-chip").forEach(c => {
      const active = parseInt(c.dataset.sec, 10) === step.sectionId
      c.className = `sec-chip px-2.5 py-1 rounded-xl text-xs font-bold cursor-pointer transition ${active ? "bg-blue-600 text-white" : "card text-[var(--text-main)]"}`
    })

    document.querySelectorAll(".tl-pill").forEach((p, idx) => {
      p.className = `tl-pill px-2 py-0.5 rounded-lg text-[11px] font-mono-code font-bold cursor-pointer whitespace-nowrap ${idx === this.state.stepIndex ? "bg-emerald-600 text-white" : "card text-[var(--text-muted)]"}`
    })

    this.renderSheetSVG()
    KeyboardRenderer.updateHighlights({
      pianoBedEl: this.pianoBedEl,
      voiceBedEl: this.voiceBedEl,
      step,
      state: this.state
    })
  }

  triggerTickAudio(step, tick) {
    if (!step || !step.levels) return
    const lv = step.levels[this.state.level] || step.levels.faithful || step.levels.original || step.levels.easy
    if (!lv) return
    const secPerTick = (60 / this.state.bpm) / 4
    const timbre = document.getElementById("voice-timbre-select")?.value || "rhodes"

    if (document.getElementById("chk-metro")?.checked && tick % 4 === 0) {
      this.audio.playMetroClick(tick === 0)
    }
    if (this.state.handMode !== "rh") {
      ;(lv.lh || []).filter(e => e.tick === tick).forEach(e => {
        ;(e.notes || []).forEach(n => this.audio.playTone(n, Math.max(0.25, e.dur * secPerTick * 0.95), 0.72, false))
      })
    }
    if (this.state.handMode !== "lh") {
      ;(lv.rh || []).filter(e => e.tick === tick).forEach(e => {
        ;(e.notes || []).forEach(n => this.audio.playTone(n, Math.max(0.22, e.dur * secPerTick * 0.92), 0.78, false))
      })
    }
    if (this.state.showVoicePanel && document.getElementById("chk-voice-audio")?.checked && step.voice) {
      step.voice.filter(v => v.tick === tick).forEach(v => {
        this.audio.playTone(v.note, Math.max(0.25, v.dur * secPerTick * 0.95), 0.65, true, timbre)
      })
    }
  }

  stopPlay(resetTick = true) {
    this.state.isPlaying = false
    if (this.state.timer) {
      clearInterval(this.state.timer)
      this.state.timer = null
    }
    if (resetTick) this.state.activeTick = -1
    const btnSong = document.getElementById("btn-play-song")
    const btnSec = document.getElementById("btn-play-section")
    const btnStep = document.getElementById("btn-play-step")
    if (btnSong) btnSong.textContent = "🎵 Música Inteira"
    if (btnSec) btnSec.textContent = "▶▶ Seção"
    if (btnStep) btnStep.textContent = "▶ Compasso"
    this.renderMeasureView()
  }

  startPlay(mode, keepCurrentTick = false) {
    if (this.state.isPlaying && !keepCurrentTick && this.state.playMode === mode) {
      this.stopPlay(true)
      return
    }
    if (this.state.timer) clearInterval(this.state.timer)
    this.audio.ensureAudioCtx()
    this.state.isPlaying = true
    this.state.playMode = mode
    this.state.frozenTick = -1

    if (!keepCurrentTick) {
      this.state.activeTick = 0
      this.triggerTickAudio(this.steps[this.state.stepIndex], 0)
    }

    document.getElementById("btn-play-song").textContent = mode === "song" ? "⏸ Pausar" : "🎵 Música Inteira"
    document.getElementById("btn-play-section").textContent = mode === "section" ? "⏸ Pausar" : "▶▶ Seção"
    document.getElementById("btn-play-step").textContent = mode === "step" ? "⏸ Pausar" : "▶ Compasso"
    this.renderMeasureView()

    const tickMs = ((60 / this.state.bpm) / 4) * 1000
    const maxTicks = this.state.ticksPerMeasure || 16
    this.state.timer = setInterval(() => {
      this.state.activeTick++
      if (this.state.activeTick >= maxTicks) {
        this.state.activeTick = 0
        const loop = document.getElementById("chk-loop")?.checked
        const curStep = this.steps[this.state.stepIndex]

        if (this.state.playMode === "step") {
          if (!loop) { this.stopPlay(true); return }
        } else if (this.state.playMode === "section") {
          const nextStep = this.steps[this.state.stepIndex + 1]
          if (nextStep && nextStep.sectionId === curStep.sectionId) {
            this.state.stepIndex++
          } else if (loop) {
            this.state.stepIndex = this.steps.findIndex(s => s.sectionId === curStep.sectionId)
          } else {
            this.stopPlay(true)
            return
          }
        } else if (this.state.playMode === "song") {
          if (this.state.stepIndex < this.steps.length - 1) {
            this.state.stepIndex++
          } else if (loop) {
            this.state.stepIndex = 0
          } else {
            this.stopPlay(true)
            return
          }
        }
      }
      this.triggerTickAudio(this.steps[this.state.stepIndex], this.state.activeTick)
      this.renderMeasureView()
    }, tickMs)
  }

  buildTimelineOnce() {
    const tabBox = document.getElementById("section-tabs")
    const tlBox = document.getElementById("timeline-strip")
    if (!tabBox || !tlBox) return
    tabBox.innerHTML = ""
    tlBox.innerHTML = ""

    this.sections.forEach(sec => {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.dataset.sec = sec.id
      btn.className = "sec-chip px-2.5 py-1 rounded-xl text-xs font-bold card cursor-pointer"
      btn.textContent = sec.name
      btn.addEventListener("click", () => {
        const idx = this.steps.findIndex(s => s.sectionId === sec.id)
        if (idx !== -1) {
          this.state.stepIndex = idx
          this.state.frozenTick = -1
          if (this.state.isPlaying) this.state.activeTick = 0
          this.renderMeasureView()
        }
      })
      tabBox.appendChild(btn)
    })

    this.steps.forEach((st, idx) => {
      const pill = document.createElement("button")
      pill.type = "button"
      pill.className = "tl-pill px-2 py-0.5 rounded-lg text-[11px] font-mono-code font-bold card cursor-pointer"
      pill.textContent = `${st.id}`
      pill.title = `${st.tag} — ${st.title}`
      pill.addEventListener("click", () => {
        this.state.stepIndex = idx
        this.state.frozenTick = -1
        if (this.state.isPlaying) this.state.activeTick = 0
        this.renderMeasureView()
      })
      tlBox.appendChild(pill)
    })
  }

  async applySongPack(songId) {
    if (!this.songs[songId]) {
      try {
        const resp = await fetch(`/songs/${encodeURIComponent(songId)}.json`)
        if (resp.ok) {
          const data = await resp.json()
          if (data.steps) this.songs[songId] = data
        }
      } catch (_e) {
        return
      }
    }
    if (!this.songs[songId]) return
    if (this.state.isPlaying) this.stopPlay(true)

    this.state.songId = songId
    const pack = this.songs[songId]
    this.sections = pack.sections || []
    this.steps = pack.steps || []
    this.state.ticksPerMeasure = pack.meta?.ticksPerMeasure || 16
    this.state.stepIndex = 0
    this.state.activeTick = -1
    this.state.frozenTick = -1

    document.getElementById("song-meta-tag").textContent = pack.meta.info

    const sel = document.getElementById("step-select")
    sel.innerHTML = ""
    this.sections.forEach(sec => {
      const grp = document.createElement("optgroup")
      grp.label = sec.name
      this.steps.forEach((st, i) => {
        if (st.sectionId !== sec.id) return
        const opt = document.createElement("option")
        opt.value = i
        opt.textContent = `${st.tag} — ${st.title}`
        grp.appendChild(opt)
      })
      sel.appendChild(grp)
    })

    const presetWrap = document.getElementById("bpm-presets")
    presetWrap.innerHTML = ""
    ;(pack.meta.presets || [76]).forEach(b => {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "px-2 py-1 rounded-lg text-[11px] font-mono-code font-bold card text-[var(--text-main)] cursor-pointer"
      btn.textContent = String(b)
      btn.addEventListener("click", () => this.setBpm(b))
      presetWrap.appendChild(btn)
    })

    this.setBpm(pack.meta.defaultBpm || 76)
    this.buildTimelineOnce()
    this.renderMeasureView()
  }

  pollImportingSong(slug) {
    const badge = document.getElementById("import-status-badge")
    const checkStatus = async () => {
      try {
        const resp = await fetch(`/songs/${encodeURIComponent(slug)}.json`)
        if (!resp.ok) return
        const data = await resp.json()

        if (data.steps) {
          if (this.importPollTimer) {
            clearInterval(this.importPollTimer)
            this.importPollTimer = null
          }
          this.songs[slug] = data
          this.registerImportedSongOption(slug, data.meta?.title || slug, data.meta?.sourceType || "pdf_omr")
          this.applySongPack(slug)
          if (badge) badge.textContent = `✅ "${data.meta?.title || slug}" importada com sucesso!`
          window.history.replaceState({}, "", `/?song=${encodeURIComponent(slug)}`)
        } else if (data.status === "failed") {
          if (this.importPollTimer) {
            clearInterval(this.importPollTimer)
            this.importPollTimer = null
          }
          if (badge) badge.textContent = `❌ Falha ao importar "${data.title}": ${data.error_message || "erro desconhecido"}`
        } else if (data.status === "processing") {
          if (badge) badge.textContent = `⏳ Transcrevendo "${data.title}" no Solid Queue...`
        }
      } catch (_e) {
        // Ignore transient network errors while polling
      }
    }

    checkStatus()
    this.importPollTimer = setInterval(checkStatus, 2000)
  }

  registerImportedSongOption(slug, title, sourceType) {
    const select = document.getElementById("song-select")
    if (!select) return

    let opt = select.querySelector(`option[value="${CSS.escape(slug)}"]`)
    if (!opt) {
      let group = Array.from(select.querySelectorAll("optgroup")).find(g => g.label === "Partituras Importadas")
      if (!group) {
        group = document.createElement("optgroup")
        group.label = "Partituras Importadas"
        select.appendChild(group)
      }
      opt = document.createElement("option")
      opt.value = slug
      opt.textContent = `${title} (${String(sourceType).toUpperCase()})`
      group.appendChild(opt)
    }
    select.value = slug
  }

  setBpm(v) {
    this.state.bpm = v
    document.getElementById("bpm-slider").value = v
    document.getElementById("bpm-text").textContent = `${v} BPM`
    if (this.state.isPlaying) this.startPlay(this.state.playMode, true)
  }

  updateHandButtons() {
    document.querySelectorAll(".hand-btn").forEach(btn => {
      const active = btn.dataset.hand === this.state.handMode
      btn.className = `hand-btn px-2.5 py-1 rounded-lg text-xs font-bold cursor-pointer transition ${active ? "bg-blue-600 text-white shadow-sm" : "text-[var(--text-main)] hover:opacity-80"}`
    })
  }

  bindUIEvents() {
    document.getElementById("song-select")?.addEventListener("change", e => this.applySongPack(e.target.value))
    document.getElementById("level-select")?.addEventListener("change", e => {
      this.state.level = e.target.value
      this.renderMeasureView()
    })

    document.getElementById("btn-play-song")?.addEventListener("click", () => this.startPlay("song"))
    document.getElementById("btn-play-section")?.addEventListener("click", () => this.startPlay("section"))
    document.getElementById("btn-play-step")?.addEventListener("click", () => this.startPlay("step"))

    document.getElementById("btn-prev")?.addEventListener("click", () => {
      if (this.state.stepIndex > 0) {
        this.state.stepIndex--
        this.state.frozenTick = -1
        this.renderMeasureView()
      }
    })
    document.getElementById("btn-next")?.addEventListener("click", () => {
      if (this.state.stepIndex < this.steps.length - 1) {
        this.state.stepIndex++
        this.state.frozenTick = -1
        this.renderMeasureView()
      }
    })
    document.getElementById("step-select")?.addEventListener("change", e => {
      this.state.stepIndex = parseInt(e.target.value, 10)
      this.state.frozenTick = -1
      this.renderMeasureView()
    })

    document.getElementById("btn-sheet-zoom")?.addEventListener("click", e => {
      this.state.zoomOneMeasure = !this.state.zoomOneMeasure
      e.target.textContent = this.state.zoomOneMeasure ? "🔍 Zoom: 1 Compasso" : "📄 2 Compassos"
      this.renderSheetSVG()
    })

    document.getElementById("chk-notes-on-sheet")?.addEventListener("change", e => {
      this.state.showCiphers = e.target.checked
      this.renderSheetSVG()
    })

    document.getElementById("btn-unfreeze")?.addEventListener("click", () => {
      this.state.frozenTick = -1
      this.renderMeasureView()
    })

    document.getElementById("btn-toggle-voice")?.addEventListener("click", () => {
      this.state.showVoicePanel = !this.state.showVoicePanel
      document.getElementById("voice-keyboard-panel")?.classList.toggle("hidden", !this.state.showVoicePanel)
      document.getElementById("legend-voice-pill")?.classList.toggle("hidden", !this.state.showVoicePanel)
      this.renderMeasureView()
    })

    document.getElementById("btn-toggle-map")?.addEventListener("click", () => {
      document.getElementById("sections-drawer")?.classList.toggle("hidden")
    })

    document.getElementById("btn-toggle-import")?.addEventListener("click", () => {
      document.getElementById("import-drawer")?.classList.toggle("hidden")
    })

    document.getElementById("btn-focus")?.addEventListener("click", () => {
      document.body.classList.toggle("focus-mode")
    })

    document.getElementById("btn-theme")?.addEventListener("click", () => {
      document.documentElement.classList.toggle("dark")
      this.renderSheetSVG()
    })

    document.getElementById("btn-mic-record")?.addEventListener("click", () => {
      this.toggleMicRecording()
    })

    document.querySelectorAll(".hand-btn").forEach(btn => {
      btn.addEventListener("click", () => {
        this.state.handMode = btn.dataset.hand
        this.updateHandButtons()
        this.renderMeasureView()
      })
    })

    document.getElementById("bpm-slider")?.addEventListener("input", e => this.setBpm(parseInt(e.target.value, 10)))

    this.keyHandler = e => {
      if (["SELECT", "INPUT"].includes(document.activeElement?.tagName)) return
      if (e.code === "Space") {
        e.preventDefault()
        this.state.isPlaying ? this.stopPlay(true) : this.startPlay("song")
      } else if (e.code === "ArrowRight" && this.state.stepIndex < this.steps.length - 1) {
        this.state.stepIndex++
        this.state.frozenTick = -1
        this.renderMeasureView()
      } else if (e.code === "ArrowLeft" && this.state.stepIndex > 0) {
        this.state.stepIndex--
        this.state.frozenTick = -1
        this.renderMeasureView()
      } else if (e.key === "f" || e.key === "F") {
        document.body.classList.toggle("focus-mode")
      }
    }
    document.addEventListener("keydown", this.keyHandler)
  }

  async toggleMicRecording() {
    const btn = document.getElementById("btn-mic-record")
    const badge = document.getElementById("import-status-badge")

    if (this.micRecorder && this.micRecorder.state === "recording") {
      this.micRecorder.stop()
      return
    }

    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === "undefined") {
      if (badge) badge.textContent = "❌ Seu navegador não suporta gravação de microfone (MediaRecorder)."
      return
    }

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      const mimeType = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
        ? "audio/webm;codecs=opus"
        : (MediaRecorder.isTypeSupported("audio/webm") ? "audio/webm" : "audio/ogg")

      this.micStream = stream
      this.micChunks = []
      this.micRecorder = new MediaRecorder(stream, { mimeType })

      this.micRecorder.ondataavailable = ev => {
        if (ev.data && ev.data.size > 0) this.micChunks.push(ev.data)
      }

      this.micRecorder.onstop = async () => {
        const chunks = this.micChunks || []
        this.cleanupMicRecorder()
        if (btn) btn.textContent = "🎙️ Gravar Microfone"
        if (!chunks.length) return

        const ext = mimeType.includes("ogg") ? "ogg" : "webm"
        const blob = new Blob(chunks, { type: mimeType })
        await this.uploadRecordedAudio(blob, ext)
      }

      this.micRecorder.start(500)
      this.micStartedAt = Date.now()
      if (btn) btn.textContent = "⏹ Parar e Transcrever (00:00)"
      if (badge) badge.textContent = "🎙️ Ouvindo música pelo microfone... clique em Parar quando terminar."

      this.micTimer = setInterval(() => {
        const secs = Math.floor((Date.now() - this.micStartedAt) / 1000)
        const mm = String(Math.floor(secs / 60)).padStart(2, "0")
        const ss = String(secs % 60).padStart(2, "0")
        if (btn) btn.textContent = `⏹ Parar e Transcrever (${mm}:${ss})`
      }, 500)
    } catch (err) {
      this.cleanupMicRecorder()
      if (badge) badge.textContent = `❌ Permissão de microfone negada ou indisponível: ${err.message}`
    }
  }

  cleanupMicRecorder() {
    if (this.micTimer) {
      clearInterval(this.micTimer)
      this.micTimer = null
    }
    if (this.micStream) {
      this.micStream.getTracks().forEach(t => t.stop())
      this.micStream = null
    }
    this.micRecorder = null
  }

  async uploadRecordedAudio(blob, ext) {
    const badge = document.getElementById("import-status-badge")
    const titleInput = document.querySelector("#import-song-form input[name='song[title]']")
    const nowLabel = new Date().toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" })
    const title = titleInput?.value?.trim() || `Captura Microfone ${nowLabel}`

    const formData = new FormData()
    formData.append("song[title]", title)
    formData.append("song[source_file]", blob, `captura-microfone.${ext}`)

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    if (badge) badge.textContent = `⏳ Enviando captura "${title}" para transcrição...`

    try {
      const resp = await fetch("/songs/import.json", {
        method: "POST",
        headers: csrfToken ? { "X-CSRF-Token": csrfToken, "Accept": "application/json" } : { "Accept": "application/json" },
        body: formData
      })
      const data = await resp.json()
      if (!resp.ok) {
        if (badge) badge.textContent = `❌ Falha ao enviar gravação: ${data.error || (data.errors || []).join(", ")}`
        return
      }
      if (data.slug) {
        this.pollImportingSong(data.slug)
      }
    } catch (err) {
      if (badge) badge.textContent = `❌ Erro de rede ao enviar gravação: ${err.message}`
    }
  }
}
