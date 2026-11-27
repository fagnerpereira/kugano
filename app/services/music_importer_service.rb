require "nokogiri"

class MusicImporterService
  SHARP_NAMES = %w[C C# D D# E F F# G G# A A# B].freeze
  BASE_OFFSETS = { "C" => 0, "D" => 2, "E" => 4, "F" => 5, "G" => 7, "A" => 9, "B" => 11 }.freeze
  FIFTHS_MAJOR = {
    -7 => "Cb", -6 => "Gb", -5 => "Db", -4 => "Ab", -3 => "Eb", -2 => "Bb", -1 => "F",
    0 => "C", 1 => "G", 2 => "D", 3 => "A", 4 => "E", 5 => "B", 6 => "F#", 7 => "C#"
  }.freeze
  FIFTHS_MINOR = {
    -7 => "Abm", -6 => "Ebm", -5 => "Bbm", -4 => "Fm", -3 => "Cm", -2 => "Gm", -1 => "Dm",
    0 => "Am", 1 => "Em", 2 => "Bm", 3 => "F#m", 4 => "C#m", 5 => "G#m", 6 => "D#m", 7 => "A#m"
  }.freeze
  KIND_SUFFIX = {
    "major" => "", "minor" => "m", "dominant" => "7", "major-seventh" => "maj7",
    "minor-seventh" => "m7", "diminished" => "dim", "diminished-seventh" => "dim7",
    "augmented" => "aug", "suspended-fourth" => "sus4", "major-sixth" => "6", "minor-sixth" => "m6"
  }.freeze

  def self.call(content:, filename:, slug: nil, title: nil, artist: nil)
    new(content: content, filename: filename, slug: slug, title: title, artist: artist).call
  end

  def initialize(content:, filename:, slug: nil, title: nil, artist: nil)
    @content = content.to_s
    @filename = filename.to_s
    @title = title
    @artist = artist
    @slug = (slug.presence || File.basename(@filename, ".*").parameterize.presence || "imported-song")
  end

  def call
    ext = File.extname(@filename).downcase
    if %w[.mid .midi].include?(ext) || @content.b.start_with?("MThd".b)
      parse_midi(@content.b)
    else
      xml_str = (ext == ".mxl" || @content.b.start_with?("PK\x03\x04".b)) ? extract_mxl(@content.b) : @content
      parse_musicxml(xml_str)
    end
  end

  private

  def midi_to_id(midi)
    m = midi.to_i.clamp(36, 84)
    "#{SHARP_NAMES[m % 12]}#{(m / 12) - 1}"
  end

  def step_to_midi(step, alter, octave)
    ((octave.to_i + 1) * 12) + BASE_OFFSETS.fetch(step.to_s.upcase, 0) + alter.to_i
  end

  def extract_mxl(zip_bytes)
    Dir.mktmpdir("mxl_unzip") do |dir|
      zip_path = File.join(dir, "score.mxl")
      File.binwrite(zip_path, zip_bytes)
      system("unzip", "-q", zip_path, "-d", dir)
      xml_file = Dir.glob(File.join(dir, "**", "*.{musicxml,xml}")).reject { |f| f.include?("META-INF") }.first
      raise ArgumentError, "Arquivo .mxl não contém XML válido" unless xml_file

      File.read(xml_file)
    end
  end

  def parse_musicxml(xml_str)
    doc = Nokogiri::XML(xml_str)
    doc.remove_namespaces!

    title = @title.presence ||
            doc.at_xpath("//work-title")&.text&.strip.presence ||
            doc.at_xpath("//movement-title")&.text&.strip.presence ||
            @slug.tr("-", " ").titleize
    artist = @artist.presence || doc.at_xpath("//creator")&.text&.strip.presence || "Partitura Importada"

    part_nodes = doc.xpath("//part")
    raise ArgumentError, "MusicXML sem <part>" if part_nodes.empty?

    piano_part, voice_part = detect_piano_and_voice_parts(doc, part_nodes)
    measures = piano_part.xpath("./measure")
    raise ArgumentError, "MusicXML sem <measure>" if measures.empty?

    voice_measures = voice_part ? voice_part.xpath("./measure").each_with_index.to_h { |m, i| [ i + 1, m ] } : {}

    divisions = 4
    fifths = 0
    mode = "major"
    first_time_node = piano_part.at_xpath(".//time")
    beats = first_time_node&.at_xpath("./beats")&.text&.to_i || 4
    beat_type = first_time_node&.at_xpath("./beat-type")&.text&.to_i || 4
    score_time_sig = "#{beats}/#{beat_type}"
    score_ticks_per_measure = ((beats * 16.0) / beat_type).round.clamp(4, 32)
    bpm = 76
    sections = []
    steps = []

    measures.each_with_index do |m_node, idx|
      m_id = idx + 1
      sec_id = (idx / 8) + 1
      if sections.none? { |s| s["id"] == sec_id }
        sections << { "id" => sec_id, "name" => "#{sec_id}. Compassos #{((sec_id - 1) * 8) + 1}–#{[ sec_id * 8, measures.size ].min}" }
      end

      divisions = [ m_node.at_xpath(".//divisions")&.text.to_i, 1 ].max if m_node.at_xpath(".//divisions")
      if (f_node = m_node.at_xpath(".//key/fifths"))
        fifths = f_node.text.to_i
        mode = m_node.at_xpath(".//key/mode")&.text&.strip.presence || "major"
      end
      if (b_node = m_node.at_xpath(".//time/beats"))
        beats = b_node.text.to_i
        beat_type = (m_node.at_xpath(".//time/beat-type")&.text || "4").to_i
      end
      if (s_node = m_node.at_xpath(".//sound[@tempo]"))
        bpm = s_node["tempo"].to_f.round.clamp(30, 240)
      elsif (met_node = m_node.at_xpath(".//metronome/per-minute"))
        bpm = met_node.text.to_f.round.clamp(30, 240)
      end

      m_divs = [ (divisions * beats * (4.0 / beat_type)).round, 1 ].max
      lh_buckets = {}
      rh_buckets = {}
      lyrics = []
      cursor = 0
      last_onset = 0

      m_node.children.each do |child|
        case child.name
        when "backup"
          cursor = [ cursor - child.at_xpath("./duration")&.text.to_i, 0 ].max
        when "forward"
          cursor += child.at_xpath("./duration")&.text.to_i
        when "note"
          next if child.at_xpath("./grace").present?
          is_chord = child.at_xpath("./chord").present?
          dur_div = [ child.at_xpath("./duration")&.text.to_i, 1 ].max
          onset = is_chord ? last_onset : cursor
          is_tied_stop_only = child.at_xpath("./tie[@type='stop']").present? && child.at_xpath("./tie[@type='start']").blank?

          if !is_tied_stop_only && child.at_xpath("./rest").blank? && (step_txt = child.at_xpath("./pitch/step")&.text&.strip).present?
            midi = step_to_midi(step_txt, child.at_xpath("./pitch/alter")&.text.to_i, child.at_xpath("./pitch/octave")&.text.to_i)
            note_id = midi_to_id(midi)
            staff = child.at_xpath("./staff")&.text&.to_i
            is_lh = staff ? (staff >= 2) : (midi < 60)

            tick = ((onset.to_f / m_divs) * score_ticks_per_measure).round.clamp(0, score_ticks_per_measure - 1)
            dur = ((dur_div.to_f / m_divs) * score_ticks_per_measure).round.clamp(1, score_ticks_per_measure - tick)
            f_val = child.at_xpath(".//fingering")&.text&.to_i
            finger = (f_val && f_val.between?(1, 5)) ? f_val : nil

            target = is_lh ? lh_buckets : rh_buckets
            bucket = (target[tick] ||= { "tick" => tick, "dur" => dur, "items" => [] })
            bucket["dur"] = [ bucket["dur"], dur ].max
            bucket["items"] << [ midi, note_id, finger ]
          end

          child.xpath("./lyric/text").each { |lt| lyrics << lt.text.strip if lt.text.to_s.strip.present? }
          unless is_chord
            last_onset = cursor
            cursor += dur_div
          end
        end
      end

      v_events, v_lyrics = extract_voice_measure(voice_measures[m_id], m_divs, score_ticks_per_measure)
      lyrics.concat(v_lyrics) if lyrics.empty?

      lh_events = finalize_buckets(lh_buckets, hand: :lh)
      rh_events = finalize_buckets(rh_buckets, hand: :rh)
      rh_events = [ { "tick" => 0, "dur" => score_ticks_per_measure, "notes" => [ "C4" ], "fingers" => [ 1 ] } ] if lh_events.empty? && rh_events.empty?

      chord_name = extract_harmony(m_node) || infer_chord(lh_events, rh_events)

      steps << {
        "id" => m_id,
        "tag" => "Comp. #{m_id}",
        "sectionId" => sec_id,
        "title" => "Comp. #{m_id} — #{chord_name}",
        "lyric" => lyrics.any? ? lyrics.join(" ") : "Compasso #{m_id}",
        "voice" => v_events,
        "levels" => ProgressiveLevelGenerator.generate(
          chord: chord_name,
          pedal: m_node.xpath(".//pedal").any?,
          lh_events: lh_events,
          rh_events: rh_events,
          ticks_per_measure: score_ticks_per_measure
        )
      }
    end

    key_name = mode == "minor" ? FIFTHS_MINOR.fetch(fifths, "Am") : FIFTHS_MAJOR.fetch(fifths, "C")
    build_schema_payload(
      title: title,
      artist: artist,
      key: key_name,
      bpm: bpm,
      time_sig: score_time_sig,
      ticks_per_measure: score_ticks_per_measure,
      source_type: "musicxml",
      sections: sections,
      steps: steps
    )
  end

  def detect_piano_and_voice_parts(doc, part_nodes)
    return [ part_nodes.first, nil ] if part_nodes.size == 1

    part_names = doc.xpath("//score-part").each_with_object({}) do |sp, h|
      h[sp["id"]] = sp.at_xpath("./part-name")&.text.to_s.downcase
    end

    piano = part_nodes.find { |p| p.at_xpath(".//staves")&.text.to_i >= 2 || part_names[p["id"]].to_s.match?(/piano|pno|keys/) } || part_nodes.last
    voice = part_nodes.find { |p| p != piano }
    [ piano, voice ]
  end

  def extract_voice_measure(v_node, m_divs, ticks_per_measure = 16)
    return [ [], [] ] unless v_node

    cursor = 0
    events = []
    lyrics = []

    v_node.children.each do |child|
      next unless child.name == "note"
      next if child.at_xpath("./chord").present? || child.at_xpath("./grace").present?

      dur_div = [ child.at_xpath("./duration")&.text.to_i, 1 ].max
      is_tied_stop_only = child.at_xpath("./tie[@type='stop']").present? && child.at_xpath("./tie[@type='start']").blank?
      if !is_tied_stop_only && child.at_xpath("./rest").blank? && (step_txt = child.at_xpath("./pitch/step")&.text&.strip).present?
        midi = step_to_midi(step_txt, child.at_xpath("./pitch/alter")&.text.to_i, child.at_xpath("./pitch/octave")&.text.to_i)
        tick = ((cursor.to_f / m_divs) * ticks_per_measure).round.clamp(0, ticks_per_measure - 1)
        dur = ((dur_div.to_f / m_divs) * ticks_per_measure).round.clamp(1, ticks_per_measure - tick)
        events << { "tick" => tick, "dur" => dur, "note" => midi_to_id(midi) }
      end
      child.xpath("./lyric/text").each { |lt| lyrics << lt.text.strip if lt.text.to_s.strip.present? }
      cursor += dur_div
    end

    [ events, lyrics ]
  end

  def parse_midi(bytes)
    raise ArgumentError, "Cabeçalho MIDI inválido (MThd ausente)" unless bytes.start_with?("MThd".b)

    header_len, _fmt, num_tracks, division = bytes[4, 10].unpack("Nn3")
    ppqn = (division & 0x7FFF).nonzero? || 96
    pos = 8 + header_len
    bpm = 100
    num = 4
    den = 4
    all_notes = []

    num_tracks.times do |t_idx|
      break if pos >= bytes.bytesize
      chunk_id = bytes[pos, 4]
      chunk_len = bytes[pos + 4, 4].unpack1("N")
      track_bytes = bytes[pos + 8, chunk_len]
      pos += 8 + chunk_len
      next unless chunk_id == "MTrk".b && track_bytes

      res = parse_midi_track(track_bytes, t_idx)
      bpm = res[:bpm] if res[:bpm]
      num = res[:num] if res[:num]
      den = res[:den] if res[:den]
      all_notes.concat(res[:notes])
    end

    raise ArgumentError, "MIDI sem notas" if all_notes.empty?

    m_ticks = [ (ppqn * num * (4.0 / den)).round, 1 ].max
    total_measures = [ ((all_notes.map { |n| n[:end_tick] }.max || m_ticks).to_f / m_ticks).ceil, 1 ].max
    sections = []
    steps = []

    total_measures.times do |m_idx|
      m_id = m_idx + 1
      sec_id = (m_idx / 8) + 1
      if sections.none? { |s| s["id"] == sec_id }
        sections << { "id" => sec_id, "name" => "#{sec_id}. Compassos #{((sec_id - 1) * 8) + 1}–#{[ sec_id * 8, total_measures ].min}" }
      end

      m_start = m_idx * m_ticks
      m_end = m_start + m_ticks
      lh_buckets = {}
      rh_buckets = {}

      all_notes.select { |n| n[:start_tick] >= m_start && n[:start_tick] < m_end }.each do |n|
        tick = (((n[:start_tick] - m_start).to_f / m_ticks) * 16).round.clamp(0, 15)
        dur = (([ n[:end_tick] - n[:start_tick], 1 ].max.to_f / m_ticks) * 16).round.clamp(1, 16 - tick)
        midi = n[:midi].clamp(36, 84)
        note_id = midi_to_id(midi)
        target = midi < 60 ? lh_buckets : rh_buckets
        bucket = (target[tick] ||= { "tick" => tick, "dur" => dur, "items" => [] })
        bucket["dur"] = [ bucket["dur"], dur ].max
        bucket["items"] << [ midi, note_id, nil ]
      end

      lh_events = finalize_buckets(lh_buckets, hand: :lh)
      rh_events = finalize_buckets(rh_buckets, hand: :rh)
      rh_events = [ { "tick" => 0, "dur" => 16, "notes" => [ "C4" ], "fingers" => [ 1 ] } ] if lh_events.empty? && rh_events.empty?
      chord_name = infer_chord(lh_events, rh_events)

      steps << {
        "id" => m_id,
        "tag" => "Comp. #{m_id}",
        "sectionId" => sec_id,
        "title" => "Comp. #{m_id} — #{chord_name}",
        "lyric" => "Compasso #{m_id}",
        "voice" => [],
        "levels" => ProgressiveLevelGenerator.generate(chord: chord_name, pedal: false, lh_events: lh_events, rh_events: rh_events)
      }
    end

    first_chord = steps.dig(0, "levels", "original", "chord") || "C"
    build_schema_payload(
      title: @title.presence || @slug.tr("-", " ").titleize,
      artist: @artist.presence || "MIDI Importado",
      key: first_chord,
      bpm: bpm,
      time_sig: "#{num}/#{den}",
      source_type: "midi",
      sections: sections,
      steps: steps
    )
  end

  def parse_midi_track(data, track_idx)
    idx = 0
    abs_tick = 0
    running_status = 0
    active = {}
    notes = []
    bpm = nil
    num = nil
    den = nil

    while idx < data.bytesize
      delta, idx = read_vlq(data, idx)
      abs_tick += delta
      break if idx >= data.bytesize

      status = data.getbyte(idx)
      if status >= 0x80
        idx += 1
        running_status = status unless status >= 0xF0
      else
        status = running_status
      end

      case status
      when 0x80..0x8F
        pitch = data.getbyte(idx)
        idx += 2
        if (st = active.delete(pitch))
          notes << { midi: pitch, start_tick: st, end_tick: [ abs_tick, st + 1 ].max, track: track_idx }
        end
      when 0x90..0x9F
        pitch = data.getbyte(idx)
        vel = data.getbyte(idx + 1)
        idx += 2
        if vel.to_i > 0
          active[pitch] = abs_tick
        elsif (st = active.delete(pitch))
          notes << { midi: pitch, start_tick: st, end_tick: [ abs_tick, st + 1 ].max, track: track_idx }
        end
      when 0xA0..0xBF, 0xE0..0xEF then idx += 2
      when 0xC0..0xDF then idx += 1
      when 0xFF
        m_type = data.getbyte(idx)
        m_len, idx = read_vlq(data, idx + 1)
        m_bytes = data[idx, m_len]
        idx += m_len
        if m_type == 0x51 && m_bytes&.bytesize == 3
          b0, b1, b2 = m_bytes.bytes
          us = (b0 << 16) | (b1 << 8) | b2
          bpm = (60_000_000.0 / us).round.clamp(30, 240) if us > 0
        elsif m_type == 0x58 && m_bytes && m_bytes.bytesize >= 2
          num = m_bytes.getbyte(0)
          den = 2**m_bytes.getbyte(1)
        end
      when 0xF0, 0xF7
        s_len, idx = read_vlq(data, idx)
        idx += s_len
      else
        idx += 1
      end
    end

    { bpm: bpm, num: num, den: den, notes: notes }
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
      sorted = b["items"].uniq { |i| i[1] }.sort_by { |i| i[0] }
      notes = sorted.map { |i| i[1] }
      explicit = sorted.map { |i| i[2] }
      fingers = explicit.all?(&:present?) ? explicit : ProgressiveLevelGenerator.assign_fingers(notes, hand: hand)
      { "tick" => b["tick"], "dur" => b["dur"], "notes" => notes, "fingers" => fingers }
    end
  end

  def extract_harmony(m_node)
    chords = m_node.xpath("./harmony").filter_map do |h|
      root = h.at_xpath("./root/root-step")&.text&.strip
      next if root.blank?

      alt = h.at_xpath("./root/root-alter")&.text.to_i
      acc = alt == 1 ? "#" : (alt == -1 ? "b" : "")
      kind_node = h.at_xpath("./kind")
      suffix = kind_node&.[]("text").to_s.strip.presence || KIND_SUFFIX.fetch(kind_node&.text&.strip.to_s, "")

      bass_step = h.at_xpath("./bass/bass-step")&.text&.strip
      bass_alt = h.at_xpath("./bass/bass-alter")&.text.to_i
      bass_acc = bass_alt == 1 ? "#" : (bass_alt == -1 ? "b" : "")
      bass = bass_step.present? ? "/#{bass_step}#{bass_acc}" : ""

      "#{root}#{acc}#{suffix}#{bass}"
    end.uniq
    chords.any? ? chords.join(" → ") : nil
  end

  def infer_chord(lh_events, rh_events)
    root_id = lh_events.dig(0, "notes", 0) || rh_events.dig(0, "notes", 0) || "C4"
    root_id.to_s.sub(/\d\z/, "")
  end

  def build_schema_payload(title:, artist:, key:, bpm:, time_sig:, source_type:, sections:, steps:, ticks_per_measure: 16)
    {
      "schemaVersion" => "1.0",
      "slug" => @slug,
      "meta" => {
        "title" => title,
        "artist" => artist,
        "info" => "Tom: #{key} • #{bpm} BPM • #{time_sig}",
        "key" => key,
        "defaultBpm" => bpm,
        "presets" => [ [ bpm - 20, 36 ].max, [ bpm - 10, 40 ].max, bpm ].uniq,
        "timeSignature" => time_sig,
        "ticksPerMeasure" => ticks_per_measure,
        "sourceType" => source_type
      },
      "sections" => sections,
      "steps" => steps
    }
  end
end
