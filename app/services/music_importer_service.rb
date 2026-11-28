require "nokogiri"

# = Overview
#
# Deterministic parser that converts MusicXML (+*.musicxml+, +*.xml+, +*.mxl+)
# and Standard MIDI (+*.mid+, +*.midi+) files into the canonical Piano Studio
# +SongSchema+ (v1.0) with 4 connected progressive levels and ergonomic
# sequence-aware fingerings computed by {PianoFingeringSolver}.
#
# Accepts optional audio-analysis overrides (+bpm_override+, +key_override+,
# +chord_overrides+, +time_sig_override+) when invoked from the audio/YouTube
# transcription pipeline so detected chords and tempo enrich the deterministic
# MIDI note stream without using any LLM.
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

  # Pitch-class interval templates used for deterministic chord recognition.
  CHORD_TEMPLATES = [
    [ "",     [ 0, 4, 7 ] ],
    [ "m",    [ 0, 3, 7 ] ],
    [ "7",    [ 0, 4, 7, 10 ] ],
    [ "maj7", [ 0, 4, 7, 11 ] ],
    [ "m7",   [ 0, 3, 7, 10 ] ],
    [ "dim",  [ 0, 3, 6 ] ],
    [ "aug",  [ 0, 4, 8 ] ],
    [ "sus4", [ 0, 5, 7 ] ]
  ].freeze

  # Parses +content+ deterministically into a validated +SongSchema+ hash.
  def self.call(content:, filename:, slug: nil, title: nil, artist: nil,
                bpm_override: nil, key_override: nil, chord_overrides: nil, time_sig_override: nil)
    new(
      content: content,
      filename: filename,
      slug: slug,
      title: title,
      artist: artist,
      bpm_override: bpm_override,
      key_override: key_override,
      chord_overrides: chord_overrides,
      time_sig_override: time_sig_override
    ).call
  end

  def initialize(content:, filename:, slug: nil, title: nil, artist: nil,
                 bpm_override: nil, key_override: nil, chord_overrides: nil, time_sig_override: nil)
    @content = content.to_s
    @filename = filename.to_s
    @title = title
    @artist = artist
    @slug = (slug.presence || File.basename(@filename, ".*").parameterize.presence || "imported-song")
    @bpm_override = bpm_override
    @key_override = key_override
    @chord_overrides = chord_overrides.is_a?(Array) ? chord_overrides : nil
    @time_sig_override = time_sig_override
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

  # Folds out-of-range MIDI pitches by octaves into C2..C6 (36..84) so the
  # exact pitch class and chord harmony are preserved instead of clamping to C6/C2.
  def fold_midi_range(midi)
    m = midi.to_i
    m += 12 while m < 36
    m -= 12 while m > 84
    m
  end

  def midi_to_id(midi)
    m = fold_midi_range(midi)
    "#{SHARP_NAMES[m % 12]}#{(m / 12) - 1}"
  end

  def step_to_midi(step, alter, octave)
    ((octave.to_i + 1) * 12) + BASE_OFFSETS.fetch(step.to_s.upcase, 0) + alter.to_i
  end

  def extract_mxl(zip_bytes)
    Dir.mktmpdir("mxl_unzip") do |dir|
      zip_path = File.join(dir, "score.mxl")
      File.binwrite(zip_path, zip_bytes)
      ok = system("unzip", "-q", "-o", zip_path, "-d", dir, out: File::NULL, err: File::NULL)
      raise ArgumentError, "Arquivo .mxl corrompido ou ZIP inválido" unless ok

      xml_file = locate_mxl_rootfile(dir)
      raise ArgumentError, "Arquivo .mxl não contém XML válido" unless xml_file && File.exist?(xml_file)

      File.read(xml_file)
    end
  end

  def locate_mxl_rootfile(dir)
    container_path = File.join(dir, "META-INF", "container.xml")
    if File.exist?(container_path)
      container_doc = Nokogiri::XML(File.read(container_path))
      container_doc.remove_namespaces!
      rel_path = container_doc.at_xpath("//rootfile[@full-path]")&.[]("full-path")
      if rel_path.present?
        candidate = File.expand_path(rel_path, dir)
        return candidate if candidate.start_with?(File.expand_path(dir)) && File.exist?(candidate)
      end
    end

    Dir.glob(File.join(dir, "**", "*.{musicxml,xml}"))
      .reject { |f| f.include?("META-INF") }
      .max_by { |f| File.size(f) }
  end

  def parse_musicxml(xml_str)
    raise ArgumentError, "Conteúdo MusicXML vazio" if xml_str.to_s.strip.empty?

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
    beats = positive_int(first_time_node&.at_xpath("./beats")&.text, 4).clamp(1, 16)
    beat_type = valid_beat_type(first_time_node&.at_xpath("./beat-type")&.text, 4)
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

      divisions = positive_int(m_node.at_xpath(".//divisions")&.text, divisions) if m_node.at_xpath(".//divisions")
      if (f_node = m_node.at_xpath(".//key/fifths"))
        fifths = f_node.text.to_i
        mode = m_node.at_xpath(".//key/mode")&.text&.strip.presence || "major"
      end
      if (b_node = m_node.at_xpath(".//time/beats"))
        beats = positive_int(b_node.text, beats).clamp(1, 16)
        beat_type = valid_beat_type(m_node.at_xpath(".//time/beat-type")&.text, beat_type)
      end
      if (s_node = m_node.at_xpath(".//sound[@tempo]"))
        tempo_val = s_node["tempo"].to_f
        bpm = tempo_val.round.clamp(30, 240) if tempo_val > 0
      elsif (met_node = m_node.at_xpath(".//metronome/per-minute"))
        tempo_val = met_node.text.to_f
        bpm = tempo_val.round.clamp(30, 240) if tempo_val > 0
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
          cursor += [ child.at_xpath("./duration")&.text.to_i, 0 ].max
        when "note"
          next if child.at_xpath("./grace").present?
          is_chord = child.at_xpath("./chord").present?
          dur_div = [ child.at_xpath("./duration")&.text.to_i, 1 ].max
          onset = is_chord ? last_onset : cursor
          is_tied_stop_only = child.at_xpath("./tie[@type='stop']").present? && child.at_xpath("./tie[@type='start']").blank?

          if !is_tied_stop_only && child.at_xpath("./rest").blank? && (step_txt = child.at_xpath("./pitch/step")&.text&.strip).present?
            raw_midi = step_to_midi(step_txt, child.at_xpath("./pitch/alter")&.text.to_i, child.at_xpath("./pitch/octave")&.text.to_i)
            midi = fold_midi_range(raw_midi)
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

    # Optimize sequence-aware ergonomic fingerings across all measures and levels.
    PianoFingeringSolver.solve_song_steps!(steps)

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

  def positive_int(val, fallback)
    parsed = val.to_i
    parsed > 0 ? parsed : fallback
  end

  def valid_beat_type(val, fallback)
    parsed = val.to_i
    [ 1, 2, 4, 8, 16 ].include?(parsed) ? parsed : fallback
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
        midi = fold_midi_range(step_to_midi(step_txt, child.at_xpath("./pitch/alter")&.text.to_i, child.at_xpath("./pitch/octave")&.text.to_i))
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
    raise ArgumentError, "Cabeçalho MIDI truncado" if bytes.bytesize < 14

    header_len, _fmt, num_tracks, division = bytes[4, 10].unpack("Nn3")
    ppqn = (division & 0x7FFF).nonzero? || 96
    pos = 8 + header_len
    bpm = 100
    num = 4
    den = 4
    all_notes = []

    num_tracks.times do |t_idx|
      break if pos + 8 > bytes.bytesize
      chunk_id = bytes[pos, 4]
      chunk_len = bytes[pos + 4, 4].unpack1("N")
      track_bytes = bytes[pos + 8, chunk_len]
      pos += 8 + chunk_len
      next unless chunk_id == "MTrk".b && track_bytes

      res = parse_midi_track(track_bytes, t_idx)
      bpm = res[:bpm] if res[:bpm]
      num = res[:num] if res[:num] && res[:num] > 0
      den = res[:den] if res[:den] && res[:den] > 0
      all_notes.concat(res[:notes])
    end

    raise ArgumentError, "MIDI sem notas" if all_notes.empty?

    bpm = @bpm_override.to_i.clamp(30, 240) if @bpm_override.present? && @bpm_override.to_i > 0
    if @time_sig_override.present? && (ts = /\A(\d+)\/(\d+)\z/.match(@time_sig_override.to_s))
      num = ts[1].to_i.clamp(1, 16)
      den = valid_beat_type(ts[2], den)
    end

    ticks_per_measure = ((num * 16.0) / den).round.clamp(4, 32)
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
        tick = (((n[:start_tick] - m_start).to_f / m_ticks) * ticks_per_measure).round.clamp(0, ticks_per_measure - 1)
        dur = (([ n[:end_tick] - n[:start_tick], 1 ].max.to_f / m_ticks) * ticks_per_measure).round.clamp(1, ticks_per_measure - tick)
        midi = fold_midi_range(n[:midi])
        note_id = midi_to_id(midi)
        target = midi < 60 ? lh_buckets : rh_buckets
        bucket = (target[tick] ||= { "tick" => tick, "dur" => dur, "items" => [] })
        bucket["dur"] = [ bucket["dur"], dur ].max
        bucket["items"] << [ midi, note_id, nil ]
      end

      lh_events = finalize_buckets(lh_buckets, hand: :lh)
      rh_events = finalize_buckets(rh_buckets, hand: :rh)

      override_chord = @chord_overrides&.dig(m_idx).presence
      chord_name = override_chord || infer_chord(lh_events, rh_events)

      if lh_events.empty? && rh_events.empty?
        fallback_root = chord_root_note_id(chord_name, octave: 4)
        rh_events = [ { "tick" => 0, "dur" => ticks_per_measure, "notes" => [ fallback_root ], "fingers" => [ 1 ] } ]
      end

      levels = if override_chord
        build_chord_anchored_levels(
          chord: chord_name,
          lh_events: lh_events,
          rh_events: rh_events,
          ticks_per_measure: ticks_per_measure
        )
      else
        ProgressiveLevelGenerator.generate(
          chord: chord_name,
          pedal: false,
          lh_events: lh_events,
          rh_events: rh_events,
          ticks_per_measure: ticks_per_measure
        )
      end

      steps << {
        "id" => m_id,
        "tag" => "Comp. #{m_id}",
        "sectionId" => sec_id,
        "title" => "Comp. #{m_id} — #{chord_name}",
        "lyric" => "Compasso #{m_id}",
        "voice" => [],
        "levels" => levels
      }
    end

    # Optimize sequence-aware ergonomic fingerings across all measures and levels.
    PianoFingeringSolver.solve_song_steps!(steps)

    first_chord = @key_override.presence || steps.dig(0, "levels", "original", "chord") || "C"
    build_schema_payload(
      title: @title.presence || @slug.tr("-", " ").titleize,
      artist: @artist.presence || "MIDI Importado",
      key: first_chord,
      bpm: bpm,
      time_sig: "#{num}/#{den}",
      ticks_per_measure: ticks_per_measure,
      source_type: "midi",
      sections: sections,
      steps: steps
    )
  end

  # Builds 4 progressive levels for audio-transcribed tracks where harmonic chord
  # recognition (Chord-AI style) anchors Level 1 (Easy) with clean playable chords
  # + root bass so beginners can play along with the recording immediately, while
  # Levels 2–4 progressively reveal the arpeggios and full polyphonic transcription.
  def build_chord_anchored_levels(chord:, lh_events:, rh_events:, ticks_per_measure:)
    generated = ProgressiveLevelGenerator.generate(
      chord: chord,
      pedal: true,
      lh_events: lh_events,
      rh_events: rh_events,
      ticks_per_measure: ticks_per_measure
    )

    bass_note = chord_root_note_id(chord, octave: 2)
    triad_notes = chord_voicing_note_ids(chord, octave: 4)
    half = [ ticks_per_measure / 2, 1 ].max

    generated["easy"] = {
      "chord" => chord,
      "pedal" => true,
      "tip" => "Nível 1 (Acordes Base): acompanhe a gravação tocando o baixo em #{bass_note} e o acorde #{chord}.",
      "lh" => [
        { "tick" => 0, "dur" => ticks_per_measure, "notes" => [ bass_note ], "fingers" => [ 5 ] }
      ],
      "rh" => [
        { "tick" => 0, "dur" => half, "notes" => triad_notes, "fingers" => ProgressiveLevelGenerator.assign_fingers(triad_notes, hand: :rh) },
        { "tick" => half, "dur" => [ ticks_per_measure - half, 1 ].max, "notes" => triad_notes, "fingers" => ProgressiveLevelGenerator.assign_fingers(triad_notes, hand: :rh) }
      ]
    }
    generated
  end

  def chord_root_note_id(chord_name, octave: 3)
    m = /\A([A-G])([#b]?)/.match(chord_name.to_s)
    return "C#{octave}" unless m

    base = BASE_OFFSETS.fetch(m[1], 0) + (m[2] == "#" ? 1 : (m[2] == "b" ? -1 : 0))
    midi = fold_midi_range(((octave + 1) * 12) + base)
    midi_to_id(midi)
  end

  def chord_voicing_note_ids(chord_name, octave: 4)
    m = /\A([A-G])([#b]?)(.*?)(?:\/.*)?\z/.match(chord_name.to_s)
    return [ "C4", "E4", "G4" ] unless m

    root_pc = (BASE_OFFSETS.fetch(m[1], 0) + (m[2] == "#" ? 1 : (m[2] == "b" ? -1 : 0))) % 12
    quality = m[3].to_s
    intervals = case quality
    when /\Am7/ then [ 0, 3, 7 ]
    when /\Amaj7/ then [ 0, 4, 7 ]
    when /\Am(?:\z|[^a])/ then [ 0, 3, 7 ]
    when /\Adim/ then [ 0, 3, 6 ]
    when /\Aaug/ then [ 0, 4, 8 ]
    when /\Asus4/ then [ 0, 5, 7 ]
    else [ 0, 4, 7 ]
    end

    root_midi = ((octave + 1) * 12) + root_pc
    root_midi -= 12 if root_midi > 70
    intervals.map { |iv| midi_to_id(root_midi + iv) }
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
        break if idx + 2 > data.bytesize
        pitch = data.getbyte(idx)
        idx += 2
        if (st = active.delete(pitch))
          notes << { midi: pitch, start_tick: st, end_tick: [ abs_tick, st + 1 ].max, track: track_idx }
        end
      when 0x90..0x9F
        break if idx + 2 > data.bytesize
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
        break if idx >= data.bytesize
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

    # Gracefully close any dangling note-on events that lacked a trailing note-off.
    active.each do |pitch, st|
      notes << { midi: pitch, start_tick: st, end_tick: [ abs_tick, st + 1 ].max, track: track_idx }
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
      raw_notes = sorted.map { |i| i[1] }
      raw_explicit = sorted.map { |i| i[2] }
      notes, explicit = PianoFingeringSolver.cap_playable_notes(raw_notes, raw_explicit)
      has_explicit = explicit.is_a?(Array) && explicit.size == notes.size && explicit.all?(&:present?)
      fingers = has_explicit ? explicit : ProgressiveLevelGenerator.assign_fingers(notes, hand: hand)

      event = { "tick" => b["tick"], "dur" => b["dur"], "notes" => notes, "fingers" => fingers }
      event["explicit_fingers"] = true if has_explicit
      event
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

  # Deterministically infers a chord symbol (e.g. C, Am, D7, F#m) from the
  # pitch classes present in a measure, anchored by the lowest bass pitch.
  def infer_chord(lh_events, rh_events)
    all_notes = (lh_events + rh_events).flat_map { |e| Array(e["notes"]) }
    return "C" if all_notes.empty?

    bass_id = lh_events.dig(0, "notes", 0) || rh_events.dig(0, "notes", 0) || "C4"
    bass_pc = PianoFingeringSolver.note_to_midi(bass_id) % 12
    pcs = all_notes.map { |n| PianoFingeringSolver.note_to_midi(n) % 12 }.uniq
    return SHARP_NAMES[bass_pc] if pcs.size < 2

    best_name = SHARP_NAMES[bass_pc]
    best_score = -Float::INFINITY

    12.times do |root_pc|
      CHORD_TEMPLATES.each do |suffix, intervals|
        chord_pcs = intervals.map { |iv| (root_pc + iv) % 12 }
        matched = (pcs & chord_pcs).size
        missing = (chord_pcs - pcs).size
        extra = (pcs - chord_pcs).size

        score = (matched * 2.5) - (missing * 1.4) - (extra * 0.6)
        score += 1.8 if root_pc == bass_pc
        score += 0.3 if suffix.empty? || suffix == "m"

        if score > best_score
          best_score = score
          best_name = "#{SHARP_NAMES[root_pc]}#{suffix}"
        end
      end
    end

    best_name
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
