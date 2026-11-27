module Songs
  class LevelConnector
    LH_FINGER_TEMPLATES = {
      1 => [ 5 ],
      2 => [ 5, 1 ],
      3 => [ 5, 3, 1 ],
      4 => [ 5, 3, 2, 1 ],
      5 => [ 5, 4, 3, 2, 1 ]
    }.freeze

    RH_FINGER_TEMPLATES = {
      1 => [ 1 ],
      2 => [ 1, 5 ],
      3 => [ 1, 2, 4 ],
      4 => [ 1, 2, 3, 5 ],
      5 => [ 1, 2, 3, 4, 5 ]
    }.freeze

    def self.connect(base_easy, mid_layer = {}, adv_layer = {}, faithful_override = nil)
      easy_h = normalize_level(base_easy)
      mid_h = (mid_layer || {}).deep_stringify_keys
      adv_h = (adv_layer || {}).deep_stringify_keys

      medium = {
        "chord" => mid_h["chord"].presence || easy_h["chord"],
        "pedal" => mid_h.key?("pedal") ? !!mid_h["pedal"] : easy_h["pedal"],
        "tip" => mid_h["tip"].presence || easy_h["tip"],
        "lh" => merge_hand(easy_h["lh"], mid_h["lh"]),
        "rh" => merge_hand(easy_h["rh"], mid_h["rh"])
      }

      original = {
        "chord" => adv_h["chord"].presence || medium["chord"],
        "pedal" => adv_h.key?("pedal") ? !!adv_h["pedal"] : medium["pedal"],
        "tip" => adv_h["tip"].presence || medium["tip"],
        "lh" => merge_hand(medium["lh"], adv_h["lh"]),
        "rh" => merge_hand(medium["rh"], adv_h["rh"])
      }

      faithful = if faithful_override.present?
        f_h = faithful_override.deep_stringify_keys
        {
          "chord" => f_h["chord"].presence || medium["chord"],
          "pedal" => f_h.key?("pedal") ? !!f_h["pedal"] : medium["pedal"],
          "tip" => f_h["tip"].presence || medium["tip"],
          "lh" => normalize_events(f_h["lh"] || medium["lh"], hand: :lh),
          "rh" => normalize_events(f_h["rh"] || medium["rh"], hand: :rh)
        }
      else
        {
          "chord" => medium["chord"],
          "pedal" => medium["pedal"],
          "tip" => "Original Fiel: base limpa e natural aproveitando o groove sem excessos.",
          "lh" => deep_copy_events(medium["lh"]),
          "rh" => deep_copy_events(medium["rh"])
        }
      end

      {
        "easy" => easy_h,
        "medium" => medium,
        "original" => original,
        "faithful" => faithful
      }
    end

    def self.derive_from_score(chord:, pedal:, lh_events:, rh_events:, tip: nil)
      lh_orig = normalize_events(lh_events, hand: :lh)
      rh_orig = normalize_events(rh_events, hand: :rh)

      lh_easy = build_easy_lh(lh_orig)
      rh_easy = build_easy_rh(rh_orig)

      lh_med = lh_orig.map do |ev|
        notes = ev["notes"].first(2)
        {
          "tick" => ev["tick"],
          "dur" => ev["dur"],
          "notes" => notes,
          "fingers" => ensure_fingers(notes, ev["fingers"]&.first(notes.size), hand: :lh)
        }
      end

      rh_med = rh_orig.map do |ev|
        notes = ev["notes"].size > 3 ? [ ev["notes"].first, ev["notes"][1], ev["notes"].last ] : ev["notes"]
        {
          "tick" => ev["tick"],
          "dur" => ev["dur"],
          "notes" => notes,
          "fingers" => ensure_fingers(notes, nil, hand: :rh)
        }
      end

      easy_layer = {
        "chord" => chord,
        "pedal" => !!pedal,
        "tip" => "Nível 1 (Base Essencial): notas-âncora da melodia e baixo principal em #{chord}.",
        "lh" => lh_easy,
        "rh" => rh_easy
      }

      medium_layer = {
        "chord" => chord,
        "pedal" => !!pedal,
        "tip" => "Nível 2 (+ Arpejos & Groove): mantém a base do Nível 1 e adiciona o movimento rítmico.",
        "lh" => lh_med,
        "rh" => rh_med
      }

      original_layer = {
        "chord" => chord,
        "pedal" => !!pedal,
        "tip" => tip.presence || "Nível 3 (+ Detalhes Completos): partitura integral com todas as vozes.",
        "lh" => lh_orig,
        "rh" => rh_orig
      }

      faithful_layer = {
        "chord" => chord,
        "pedal" => !!pedal,
        "tip" => tip.presence || "Original Fiel: execução direta da partitura em #{chord}.",
        "lh" => lh_orig,
        "rh" => rh_orig
      }

      connect(easy_layer, medium_layer, original_layer, faithful_layer)
    end

    def self.assign_fingers(notes, hand: :rh)
      count = Array(notes).size.clamp(1, 5)
      template = hand == :lh ? LH_FINGER_TEMPLATES[count] : RH_FINGER_TEMPLATES[count]
      template.first(Array(notes).size)
    end

    def self.ensure_fingers(notes, existing_fingers, hand: :rh)
      n_list = Array(notes)
      f_list = Array(existing_fingers).map(&:to_i).select { |f| f.between?(1, 5) }
      return f_list if f_list.size == n_list.size

      assign_fingers(n_list, hand: hand)
    end

    def self.merge_hand(parent_arr, child_arr)
      p_events = deep_copy_events(parent_arr)
      c_events = deep_copy_events(child_arr)
      return p_events if c_events.empty?

      child_ticks = c_events.to_set { |x| x["tick"] }
      kept = p_events.reject { |x| child_ticks.include?(x["tick"]) }
      (kept + c_events).sort_by { |a| a["tick"] }
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

    def self.normalize_events(events, hand:)
      Array(events).map do |ev|
        e = ev.deep_stringify_keys
        notes = Array(e["notes"]).map(&:to_s)
        {
          "tick" => e["tick"].to_i.clamp(0, 31),
          "dur" => e["dur"].to_i.clamp(1, 32),
          "notes" => notes,
          "fingers" => ensure_fingers(notes, e["fingers"], hand: hand)
        }
      end.sort_by { |e| e["tick"] }
    end

    def self.deep_copy_events(events)
      Array(events).map do |ev|
        e = ev.deep_stringify_keys
        {
          "tick" => e["tick"],
          "dur" => e["dur"],
          "notes" => Array(e["notes"]).dup,
          "fingers" => Array(e["fingers"]).dup
        }
      end
    end

    def self.build_easy_lh(lh_orig)
      return [] if lh_orig.empty?

      first_note = lh_orig.first["notes"].first
      if lh_orig.size > 2
        mid_ev = lh_orig[lh_orig.size / 2]
        mid_note = mid_ev["notes"].first
        [
          { "tick" => 0, "dur" => 8, "notes" => [ first_note ], "fingers" => [ 5 ] },
          { "tick" => 8, "dur" => 8, "notes" => [ mid_note ], "fingers" => [ mid_note == first_note ? 5 : 2 ] }
        ]
      else
        [
          { "tick" => 0, "dur" => 16, "notes" => [ first_note ], "fingers" => [ 5 ] }
        ]
      end
    end

    def self.build_easy_rh(rh_orig)
      return [] if rh_orig.empty?

      beats = rh_orig.select { |ev| (ev["tick"] % 4).zero? }
      beats = [ rh_orig.first ] if beats.empty?

      beats.first(2).each_with_index.map do |ev, idx|
        tick = idx.zero? ? 0 : 8
        dur = beats.size == 1 ? 16 : 8
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
end
