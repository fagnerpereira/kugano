import { NOTE_MAP } from "./note_table"

export class AudioEngine {
  constructor() {
    this.audioCtx = null
    this.pianoInst = null
    this.voiceInsts = {}
  }

  ensureAudioCtx() {
    if (!this.audioCtx) {
      const AC = window.AudioContext || window.webkitAudioContext
      if (AC) this.audioCtx = new AC()
    }
    if (this.audioCtx && this.audioCtx.state === "suspended") {
      this.audioCtx.resume()
    }
    return this.audioCtx
  }

  async initSoundfont(badgeEl) {
    try {
      const ctx = this.ensureAudioCtx()
      if (ctx && window.Soundfont) {
        this.pianoInst = await window.Soundfont.instrument(ctx, "acoustic_grand_piano", { soundfont: "MusyngKite" })
        if (badgeEl) badgeEl.textContent = "🎹 Piano Acústico HD"
        this.voiceInsts.rhodes = await window.Soundfont.instrument(ctx, "electric_piano_1", { soundfont: "MusyngKite" })
        this.voiceInsts.oohs = await window.Soundfont.instrument(ctx, "choir_aahs", { soundfont: "MusyngKite" })
      } else if (badgeEl) {
        badgeEl.textContent = "🎹 Sintetizador WebAudio"
      }
    } catch (_e) {
      if (badgeEl) badgeEl.textContent = "🎹 Sintetizador WebAudio"
    }
  }

  playTone(noteId, durSec = 0.45, gainVal = 0.65, isVoice = false, timbre = "rhodes") {
    const nObj = NOTE_MAP[noteId]
    if (!nObj) return
    const ctx = this.ensureAudioCtx()
    if (!ctx) return
    const now = ctx.currentTime

    if (isVoice) {
      if (timbre === "rhodes" && this.voiceInsts.rhodes) {
        this.voiceInsts.rhodes.play(noteId, now, { duration: durSec, gain: gainVal * 1.1 })
        return
      }
      if (timbre === "oohs" && this.voiceInsts.oohs) {
        this.voiceInsts.oohs.play(noteId, now, { duration: durSec + 0.12, gain: gainVal * 1.1 })
        return
      }
    }

    if (this.pianoInst) {
      this.pianoInst.play(noteId, now, { duration: durSec, gain: gainVal })
      return
    }

    // Fallback WebAudio Synthesizer
    const osc = ctx.createOscillator()
    const g = ctx.createGain()
    osc.type = isVoice ? "sine" : "triangle"
    osc.frequency.setValueAtTime(nObj.freq, now)
    g.gain.setValueAtTime(0.001, now)
    g.gain.linearRampToValueAtTime(gainVal * 0.28, now + 0.015)
    g.gain.exponentialRampToValueAtTime(0.001, now + durSec)
    osc.connect(g)
    g.connect(ctx.destination)
    osc.start(now)
    osc.stop(now + durSec)
  }

  playMetroClick(accent) {
    const ctx = this.ensureAudioCtx()
    if (!ctx) return
    const now = ctx.currentTime
    const osc = ctx.createOscillator()
    const g = ctx.createGain()
    osc.type = "sine"
    osc.frequency.setValueAtTime(accent ? 1200 : 880, now)
    g.gain.setValueAtTime(0.12, now)
    g.gain.exponentialRampToValueAtTime(0.001, now + 0.045)
    osc.connect(g)
    g.connect(ctx.destination)
    osc.start(now)
    osc.stop(now + 0.05)
  }
}
