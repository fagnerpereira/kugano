module Songs
  module Parsers
    class MidiParser
      def self.parse(midi_bytes, slug:, title: nil, artist: nil, source_type: "midi")
        new(midi_bytes, slug: slug, title: title, artist: artist, source_type: source_type).parse
      end

      def initialize(midi_bytes, slug:, title: nil, artist: nil, source_type: "midi")
        @bytes = midi_bytes.to_s.b
        @slug = slug
        @title = title.presence || slug.tr("-", " ").titleize
        @artist = artist.presence || "MIDI Importado"
        @source_type = source_type
      end

      def parse
        raise ArgumentError, "Cabeçalho MIDI inválido (MThd ausente)" unless @bytes.start_with?("MThd".b)

        header_len, _format, num_tracks, division = @bytes[4, 10].unpack("Nn3")
        ppqn = (division & 0x7FFF).nonzero? || 96
        pos = 8 + header_len

        bpm = 100
        numerator = 4
        denominator = 4
        notes = []

        num_tracks.times do |track_idx|
          break if pos >= @bytes.bytesize
          chunk_id = @bytes[pos, 4]
          chunk_len = @bytes[pos + 4, 4].unpack1("N")
          track_data = @bytes[pos + 8, chunk_len]
          pos += 8 + chunk_len
          next unless chunk_id == "MTrk".b && track_data

          track_result = parse_track(track_data, track_idx)
          bpm = track_result[:bpm] if track_result[:bpm]
          numerator = track_result[:numerator] if track_result[:numerator]
          denominator = track_result[:denominator] if track_result[:denominator]
          notes.concat(track_result[:notes])
        end

        raise ArgumentError, "Arquivo MIDI não contém notas musicais" if notes.empty?

        ticks_per_measure_midi = (ppqn * numerator * (4.0 / denominator)).round
        ticks_per_measure_midi = ppqn * 4 if ticks_per_measure_midi <= 0

        max_end_tick = notes.map { |n| n[:end_tick] }.max || ticks_per_measure_midi
        total_measures = [ (max_end_tick.to_f / ticks_per_measure_midi).ceil, 1 ].max

        sections = []
        steps = []

        total_measures.times do |m_idx|
          measure_id = m_idx + 1
          section_id = (m_idx / 8) + 1
          if sections.none? { |s| s["id"] == section_id }
            start_m = ((section_id - 1) * 8) + 1
            end_m = [ section_id * 8, total_measures ].min
            sections << { "id" => section_id, "name" => "#{section_id}. Compassos #{start_m}–#{end_m}" }
          end

          m_start = m_idx * ticks_per_measure_midi
          m_end = m_start + ticks_per_measure_midi
          m_notes = notes.select { |n| n[:start_tick] >= m_start && n[:start_tick] < m_end }

          lh_buckets = {}
          rh_buckets = {}

          m_notes.each do |n|
            rel_start = n[:start_tick] - m_start
            rel_dur = [ n[:end_tick] - n[:start_tick], 1 ].max
            tick = ((rel_start.to_f / ticks_per_measure_midi) * 16).round.clamp(0, 15)
            dur = ((rel_dur.to_f / ticks_per_measure_midi) * 16).round.clamp(1, 16 - tick)

            midi_pitch = n[:midi].clamp(36, 84)
            note_id = Songs::CipherFormatter.midi_to_id(midi_pitch)
            is_lh = midi_pitch < 60

            target = is_lh ? lh_buckets : rh_buckets
            bucket = (target[tick] ||= { "tick" => tick, "dur" => dur, "pitches" => [] })
            bucket["dur"] = [ bucket["dur"], dur ].max
            bucket["pitches"] << [ midi_pitch, note_id ]
          end

          lh_events = finalize_buckets(lh_buckets, hand: :lh)
          rh_events = finalize_buckets(rh_buckets, hand: :rh)

          if lh_events.empty? && rh_events.empty?
            rh_events = [ { "tick" => 0, "dur" => 16, "notes" => [ "C4" ], "fingers" => [ 1 ] } ]
          end

          chord_label = infer_chord(lh_events, rh_events)

          steps << {
            "id" => measure_id,
            "tag" => "Comp. #{measure_id}",
            "sectionId" => section_id,
            "title" => "Comp. #{measure_id} — #{chord_label}",
            "lyric" => "Compasso #{measure_id}",
            "voice" => [],
            "levels" => Songs::LevelConnector.derive_from_score(
              chord: chord_label,
              pedal: false,
              lh_events: lh_events,
              rh_events: rh_events
            )
          }
        end

        PianoFingeringSolver.solve_song_steps!(steps)

        first_chord = steps.dig(0, "levels", "original", "chord") || "C"
        time_sig = "#{numerator}/#{denominator}"
        presets = [ [ bpm - 20, 36 ].max, [ bpm - 10, 40 ].max, bpm ].uniq

        {
          "schemaVersion" => "1.0",
          "slug" => @slug,
          "meta" => {
            "title" => @title,
            "artist" => @artist,
            "info" => "Tom: #{first_chord} • #{bpm} BPM • #{time_sig}",
            "key" => first_chord,
            "defaultBpm" => bpm,
            "presets" => presets,
            "timeSignature" => time_sig,
            "ticksPerMeasure" => 16,
            "sourceType" => @source_type
          },
          "sections" => sections,
          "steps" => steps
        }
      end

      private

      def parse_track(data, track_idx)
        idx = 0
        abs_tick = 0
        running_status = 0
        active_notes = {}
        completed_notes = []
        bpm = nil
        numerator = nil
        denominator = nil

        while idx < data.bytesize
          delta, idx = read_vlq(data, idx)
          abs_tick += delta
          break if idx >= data.bytesize

          status_byte = data.getbyte(idx)
          if status_byte >= 0x80
            idx += 1
            running_status = status_byte unless status_byte >= 0xF0
          else
            status_byte = running_status
          end

          case status_byte
          when 0x80..0x8F
            pitch = data.getbyte(idx)
            idx += 2
            if (start_tick = active_notes.delete(pitch))
              completed_notes << { midi: pitch, start_tick: start_tick, end_tick: [ abs_tick, start_tick + 1 ].max, track: track_idx }
            end
          when 0x90..0x9F
            pitch = data.getbyte(idx)
            velocity = data.getbyte(idx + 1)
            idx += 2
            if velocity.to_i > 0
              active_notes[pitch] = abs_tick
            elsif (start_tick = active_notes.delete(pitch))
              completed_notes << { midi: pitch, start_tick: start_tick, end_tick: [ abs_tick, start_tick + 1 ].max, track: track_idx }
            end
          when 0xA0..0xBF, 0xE0..0xEF
            idx += 2
          when 0xC0..0xDF
            idx += 1
          when 0xFF
            meta_type = data.getbyte(idx)
            idx += 1
            meta_len, idx = read_vlq(data, idx)
            meta_bytes = data[idx, meta_len]
            idx += meta_len

            if meta_type == 0x51 && meta_bytes && meta_bytes.bytesize == 3
              b0, b1, b2 = meta_bytes.bytes
              microseconds = (b0 << 16) | (b1 << 8) | b2
              bpm = (60_000_000.0 / microseconds).round.clamp(30, 240) if microseconds > 0
            elsif meta_type == 0x58 && meta_bytes && meta_bytes.bytesize >= 2
              numerator = meta_bytes.getbyte(0)
              denominator = 2**meta_bytes.getbyte(1)
            end
          when 0xF0, 0xF7
            sysex_len, idx = read_vlq(data, idx)
            idx += sysex_len
          else
            idx += 1
          end
        end

        { bpm: bpm, numerator: numerator, denominator: denominator, notes: completed_notes }
      end

      def read_vlq(data, idx)
        val = 0
        while idx < data.bytesize
          byte = data.getbyte(idx)
          idx += 1
          val = (val << 7) | (byte & 0x7F)
          break if (byte & 0x80).zero?
        end
        [ val, idx ]
      end

      def finalize_buckets(buckets, hand:)
        buckets.values.sort_by { |b| b["tick"] }.map do |b|
          sorted = b["pitches"].uniq { |p| p[1] }.sort_by { |p| p[0] }
          notes = sorted.map { |p| p[1] }
          {
            "tick" => b["tick"],
            "dur" => b["dur"],
            "notes" => notes,
            "fingers" => Songs::LevelConnector.assign_fingers(notes, hand: hand)
          }
        end
      end

      def infer_chord(lh_events, rh_events)
        all_notes = (lh_events + rh_events).flat_map { |e| e["notes"] }
        return "C" if all_notes.empty?

        root_id = lh_events.dig(0, "notes", 0) || rh_events.dig(0, "notes", 0)
        root_name = root_id.to_s.sub(/\d\z/, "")
        root_pc = Songs::CipherFormatter.id_to_midi(root_id).to_i % 12
        pcs = all_notes.filter_map { |n| Songs::CipherFormatter.id_to_midi(n)&.modulo(12) }.uniq
        intervals = pcs.map { |pc| (pc - root_pc) % 12 }

        intervals.include?(3) && !intervals.include?(4) ? "#{root_name}m" : root_name
      end
    end
  end
end
