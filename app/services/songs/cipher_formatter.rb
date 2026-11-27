module Songs
  class CipherFormatter
    SHARP_NAMES = %w[C C# D D# E F F# G G# A A# B].freeze
    FLAT_TO_SHARP = {
      "Db" => "C#",
      "Eb" => "D#",
      "Fb" => "E",
      "Gb" => "F#",
      "Ab" => "G#",
      "Bb" => "A#",
      "Cb" => "B"
    }.freeze
    FLAT_DISPLAY = {
      "A#" => "Bb",
      "D#" => "Eb",
      "G#" => "Ab",
      "F#" => "Gb",
      "C#" => "Db"
    }.freeze

    def self.midi_to_id(midi)
      m = midi.to_i.clamp(21, 108)
      oct = (m / 12) - 1
      "#{SHARP_NAMES[m % 12]}#{oct}"
    end

    def self.id_to_midi(note_id)
      match = /\A([A-G](?:#|b)?)(\d)\z/.match(note_id.to_s.strip)
      return nil unless match

      pitch_name = FLAT_TO_SHARP.fetch(match[1], match[1])
      oct = match[2].to_i
      semitone = SHARP_NAMES.index(pitch_name)
      return nil unless semitone

      ((oct + 1) * 12) + semitone
    end

    def self.normalize_note_id(step, alter, octave)
      midi = step_alter_octave_to_midi(step, alter, octave)
      midi_to_id(midi)
    end

    def self.step_alter_octave_to_midi(step, alter, octave)
      base_offsets = { "C" => 0, "D" => 2, "E" => 4, "F" => 5, "G" => 7, "A" => 9, "B" => 11 }
      semitone = base_offsets.fetch(step.to_s.upcase, 0) + alter.to_i
      ((octave.to_i + 1) * 12) + semitone
    end

    def self.display_cipher(note_id, chord_name = nil)
      match = /\A([A-G]#?)(\d)\z/.match(note_id.to_s)
      return note_id.to_s unless match

      base = match[1]
      oct = match[2]

      if chord_name.present? && chord_name.match?(/(Gm|Eb|Bb|Fm|Cm|C7|\bF\b|F7|Ab|Gb|Db|dim7)/) && FLAT_DISPLAY.key?(base)
        if %w[F# C#].include?(base) && !chord_name.match?(/(Gb|Db|Abm|Binks)/)
          return "#{base}#{oct}"
        end
        if base != "G#" || chord_name.match?(/(Ab|Fm|Eb|Bb|Bdim7)/)
          base = FLAT_DISPLAY[base]
        end
      end

      "#{base}#{oct}"
    end
  end
end
