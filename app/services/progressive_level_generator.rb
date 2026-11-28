class ProgressiveLevelGenerator
  LH_FINGERS = {
    1 => [ 5 ],
    2 => [ 5, 1 ],
    3 => [ 5, 3, 1 ],
    4 => [ 5, 3, 2, 1 ],
    5 => [ 5, 4, 3, 2, 1 ]
  }.freeze

  RH_FINGERS = {
    1 => [ 1 ],
    2 => [ 1, 5 ],
    3 => [ 1, 2, 4 ],
    4 => [ 1, 2, 3, 5 ],
    5 => [ 1, 2, 3, 4, 5 ]
  }.freeze

  # Assigns deterministic fallback fingers (1..5) for a single isolated chord/event.
  # Caps chords larger than 5 notes cleanly so fingers always match notes length.
  def self.assign_fingers(notes, hand: :rh)
    n_size = Array(notes).size
    return [] if n_size.zero?

    count = n_size.clamp(1, 5)
    template = hand == :lh ? LH_FINGERS[count] : RH_FINGERS[count]
    if n_size <= 5
      template.first(n_size)
    else
      template + Array.new(n_size - 5, hand == :lh ? 1 : 5)
    end
  end

  def self.ensure_fingers(notes, fingers, hand: :rh)
    n_list = Array(notes)
    f_list = Array(fingers).map(&:to_i).select { |f| f.between?(1, 5) }
    return f_list if f_list.size == n_list.size

    assign_fingers(n_list, hand: hand)
  end

  def self.connect(easy_layer, medium_delta = {}, original_delta = {}, faithful_override = nil)
    easy = normalize_level(easy_layer)
    mid = (medium_delta || {}).deep_stringify_keys
    adv = (original_delta || {}).deep_stringify_keys

    medium = {
      "chord" => mid["chord"].presence || easy["chord"],
      "pedal" => mid.key?("pedal") ? !!mid["pedal"] : easy["pedal"],
      "tip" => mid["tip"].presence || easy["tip"],
      "lh" => merge_hand(easy["lh"], mid["lh"]),
      "rh" => merge_hand(easy["rh"], mid["rh"])
    }

    original = {
      "chord" => adv["chord"].presence || medium["chord"],
      "pedal" => adv.key?("pedal") ? !!adv["pedal"] : medium["pedal"],
      "tip" => adv["tip"].presence || medium["tip"],
      "lh" => merge_hand(medium["lh"], adv["lh"]),
      "rh" => merge_hand(medium["rh"], adv["rh"])
    }

    faithful = if faithful_override.present?
      normalize_level(faithful_override)
    else
      {
        "chord" => medium["chord"],
        "pedal" => medium["pedal"],
        "tip" => "Original Fiel: base limpa e natural aproveitando o groove sem excessos.",
        "lh" => deep_copy(medium["lh"]),
        "rh" => deep_copy(medium["rh"])
      }
    end

    {
      "easy" => easy,
      "medium" => medium,
      "original" => original,
      "faithful" => faithful
    }
  end

  def self.generate(chord:, pedal: false, lh_events:, rh_events:, tip: nil, ticks_per_measure: 16)
    lh_orig = normalize_events(lh_events, hand: :lh, ticks_per_measure: ticks_per_measure)
    rh_orig = normalize_events(rh_events, hand: :rh, ticks_per_measure: ticks_per_measure)

    easy_lh = build_easy_lh(lh_orig, ticks_per_measure: ticks_per_measure)
    easy_rh = build_easy_rh(rh_orig, ticks_per_measure: ticks_per_measure)

    med_lh = lh_orig.map do |ev|
      notes = ev["notes"].first(2)
      {
        "tick" => ev["tick"],
        "dur" => ev["dur"],
        "notes" => notes,
        "fingers" => ensure_fingers(notes, ev["fingers"]&.first(notes.size), hand: :lh)
      }
    end

    med_rh = rh_orig.map do |ev|
      notes = ev["notes"].size > 3 ? [ ev["notes"].first, ev["notes"][1], ev["notes"].last ] : ev["notes"]
      {
        "tick" => ev["tick"],
        "dur" => ev["dur"],
        "notes" => notes,
        "fingers" => ensure_fingers(notes, nil, hand: :rh)
      }
    end

    faithful_lh = lh_orig.map do |ev|
      notes = [ ev["notes"].first ]
      {
        "tick" => ev["tick"],
        "dur" => ev["dur"],
        "notes" => notes,
        "fingers" => ensure_fingers(notes, [ ev["fingers"]&.first ], hand: :lh)
      }
    end

    faithful_rh = rh_orig.map do |ev|
      notes = ev["notes"].first(3)
      {
        "tick" => ev["tick"],
        "dur" => ev["dur"],
        "notes" => notes,
        "fingers" => ensure_fingers(notes, ev["fingers"]&.first(notes.size), hand: :rh)
      }
    end

    connect(
      {
        "chord" => chord,
        "pedal" => !!pedal,
        "tip" => "Nível 1 (Base Essencial): notas-âncora da melodia e baixo principal em #{chord}.",
        "lh" => easy_lh,
        "rh" => easy_rh
      },
      {
        "chord" => chord,
        "pedal" => !!pedal,
        "tip" => "Nível 2 (+ Arpejos & Groove): reaproveita a base do Nível 1 e adiciona o movimento rítmico.",
        "lh" => med_lh,
        "rh" => med_rh
      },
      {
        "chord" => chord,
        "pedal" => !!pedal,
        "tip" => tip.presence || "Nível 3 (+ Detalhes Completos): partitura integral com todas as vozes.",
        "lh" => lh_orig,
        "rh" => rh_orig
      },
      {
        "chord" => chord,
        "pedal" => !!pedal,
        "tip" => tip.presence || "Original Fiel: execução enxuta e fiel da partitura em #{chord}.",
        "lh" => faithful_lh,
        "rh" => faithful_rh
      }
    )
  end

  def self.merge_hand(parent_arr, child_arr)
    p_events = deep_copy(parent_arr)
    c_events = deep_copy(child_arr)
    return p_events if c_events.empty?

    child_ticks = c_events.to_set { |e| e["tick"] }
    kept = p_events.reject { |e| child_ticks.include?(e["tick"]) }
    (kept + c_events).sort_by { |e| e["tick"] }
  end

  def self.normalize_level(level_hash)
    h = (level_hash || {}).deep_stringify_keys
    {
      "chord" => h["chord"].presence || "C",
      "pedal" => !!h["pedal"],
      "tip" => h["tip"].presence || "Mantenha o pulso constante.",
      "lh" => normalize_events(h["lh"], hand: :lh),
      "rh" => normalize_events(h["rh"], hand: :rh)
    }
  end

  def self.normalize_events(events, hand:, ticks_per_measure: 32)
    max_ticks = ticks_per_measure.to_i.clamp(4, 32)
    Array(events).filter_map do |ev|
      e = ev.deep_stringify_keys
      raw_notes = Array(e["notes"]).map(&:to_s).reject(&:empty?)
      next if raw_notes.empty?

      notes, raw_fingers = PianoFingeringSolver.cap_playable_notes(raw_notes, e["fingers"])
      event = {
        "tick" => e["tick"].to_i.clamp(0, max_ticks - 1),
        "dur" => e["dur"].to_i.clamp(1, max_ticks),
        "notes" => notes,
        "fingers" => ensure_fingers(notes, raw_fingers, hand: hand)
      }
      event["explicit_fingers"] = true if e["explicit_fingers"]
      event
    end.sort_by { |e| e["tick"] }
  end

  def self.deep_copy(events)
    Array(events).map do |ev|
      e = ev.deep_stringify_keys
      copy = {
        "tick" => e["tick"],
        "dur" => e["dur"],
        "notes" => Array(e["notes"]).dup,
        "fingers" => Array(e["fingers"]).dup
      }
      copy["explicit_fingers"] = true if e["explicit_fingers"]
      copy
    end
  end

  def self.build_easy_lh(lh_orig, ticks_per_measure: 16)
    return [] if lh_orig.empty?

    half = [ ticks_per_measure / 2, 1 ].max
    first_note = lh_orig.first["notes"].first
    if lh_orig.size > 2
      mid_note = lh_orig[lh_orig.size / 2]["notes"].first
      [
        { "tick" => 0, "dur" => half, "notes" => [ first_note ], "fingers" => [ 5 ] },
        { "tick" => half, "dur" => ticks_per_measure - half, "notes" => [ mid_note ], "fingers" => [ mid_note == first_note ? 5 : 2 ] }
      ]
    else
      [ { "tick" => 0, "dur" => ticks_per_measure, "notes" => [ first_note ], "fingers" => [ 5 ] } ]
    end
  end

  def self.build_easy_rh(rh_orig, ticks_per_measure: 16)
    return [] if rh_orig.empty?

    half = [ ticks_per_measure / 2, 1 ].max
    beats = rh_orig.select { |ev| (ev["tick"] % 4).zero? }
    beats = [ rh_orig.first ] if beats.empty?

    beats.first(2).each_with_index.map do |ev, idx|
      tick = idx.zero? ? 0 : half
      dur = beats.size == 1 ? ticks_per_measure : (idx.zero? ? half : ticks_per_measure - half)
      notes = ev["notes"].size > 3 ? [ ev["notes"].first, ev["notes"][1], ev["notes"].last ] : ev["notes"]
      {
        "tick" => tick,
        "dur" => dur,
        "notes" => notes,
        "fingers" => ensure_fingers(notes, nil, hand: :rh)
      }
    end
  end
end
