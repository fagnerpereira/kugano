export const SHARP_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
export const FLAT_DISPLAY = { "A#": "Bb", "D#": "Eb", "G#": "Ab", "F#": "Gb", "C#": "Db" }

export function midiToId(midi) {
  const oct = Math.floor(midi / 12) - 1
  return SHARP_NAMES[midi % 12] + oct
}

export function displayCipher(noteId, chordName) {
  const m = /^([A-G]#?)(\d)$/.exec(noteId)
  if (!m) return noteId
  let base = m[1]
  const oct = m[2]
  if (chordName && /(Gm|Eb|Bb|Fm|Cm|C7|\bF\b|F7|Ab|Gb|Db|dim7)/.test(chordName) && FLAT_DISPLAY[base]) {
    if ((base === "F#" || base === "C#") && !/(Gb|Db|Abm|Binks)/.test(chordName)) {
      return base + oct
    }
    if (base !== "G#" || /(Ab|Fm|Eb|Bb|Bdim7)/.test(chordName)) {
      base = FLAT_DISPLAY[base]
    }
  }
  return base + oct
}

export const PIANO_NOTES = []
for (let m = 36; m <= 84; m++) {
  const id = midiToId(m)
  const isBlack = id.includes("#")
  PIANO_NOTES.push({ id, midi: m, isBlack, freq: 440 * Math.pow(2, (m - 69) / 12) })
}

export const NOTE_MAP = Object.fromEntries(PIANO_NOTES.map(n => [n.id, n]))
export const VOICE_NOTES = PIANO_NOTES.filter(n => n.midi >= 55 && n.midi <= 84)
