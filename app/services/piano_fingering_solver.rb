# = Overview
#
# Deterministic, sequence-aware piano fingering solver based on a biomechanical
# Viterbi / Dynamic Programming cost model (inspired by +marcomusy/pianoplayer+
# and Nakamura et al.'s HMM piano fingering formulation).
#
# Unlike naive per-event templates that assign finger +1+ to every single-note
# right-hand event (or +5+ to every left-hand event), this solver optimizes
# fingerings across an entire sequence of events (scales, melodies, arpeggios,
# and multi-note chords) by minimizing cumulative ergonomic strain:
# * Avoids repeating the same finger on consecutive different pitches.
# * Penalizes thumb (+1+) and pinky (+5+) on black keys whenever natural alternatives exist.
# * Models anatomical white-key spans between every pair of fingers (1..5).
# * Rewards idiomatic thumb-under (+3 -> 1+, +4 -> 1+) and finger-over-thumb
#   (+1 -> 3+, +1 -> 4+) crossings while heavily penalizing non-thumb crossings.
# * Respects explicit MusicXML +<fingering>+ annotations when present and valid.
class PianoFingeringSolver
  # Base semitone offsets within an octave (C = 0 .. B = 11).
  STEP_OFFSETS = {
    "C" => 0, "D" => 2, "E" => 4, "F" => 5,
    "G" => 7, "A" => 9, "B" => 11
  }.freeze

  # Horizontal keyboard coordinate (in white-key widths) for each pitch class 0..11.
  KEY_X_OFFSETS = [
    0.0, 0.5, 1.0, 1.5, 2.0, 3.0,
    3.5, 4.0, 4.5, 5.0, 5.5, 6.0
  ].freeze

  # Pitch classes corresponding to black keys (C#, D#, F#, G#, A#).
  BLACK_KEY_PCS = [ 1, 3, 6, 8, 10 ].freeze

  # Relaxed horizontal finger offset (in white-key units) in natural 5-finger position (C-D-E-F-G).
  FINGER_ANCHOR_OFFSET = {
    1 => 0.0,
    2 => 1.0,
    3 => 2.0,
    4 => 3.0,
    5 => 4.2
  }.freeze

  # Ideal (relaxed) physical span in white-key units for each ordered finger pair.
  PAIR_IDEAL_SPAN = {
    [ 1, 2 ] => 1.3,
    [ 1, 3 ] => 2.3,
    [ 1, 4 ] => 3.5,
    [ 1, 5 ] => 4.6,
    [ 2, 3 ] => 1.0,
    [ 2, 4 ] => 2.1,
    [ 2, 5 ] => 3.3,
    [ 3, 4 ] => 1.0,
    [ 3, 5 ] => 2.1,
    [ 4, 5 ] => 1.0
  }.freeze

  # Minimum comfortable span in white-key units before cramping occurs.
  PAIR_MIN_SPAN = {
    [ 1, 2 ] => 0.5,
    [ 1, 3 ] => 1.0,
    [ 1, 4 ] => 1.8,
    [ 1, 5 ] => 2.5,
    [ 2, 3 ] => 0.5,
    [ 2, 4 ] => 1.0,
    [ 2, 5 ] => 1.8,
    [ 3, 4 ] => 0.5,
    [ 3, 5 ] => 1.0,
    [ 4, 5 ] => 0.5
  }.freeze

  # Maximum comfortable span in white-key units before severe stretch occurs.
  PAIR_MAX_SPAN = {
    [ 1, 2 ] => 4.5,
    [ 1, 3 ] => 5.8,
    [ 1, 4 ] => 7.0,
    [ 1, 5 ] => 8.2,
    [ 2, 3 ] => 2.8,
    [ 2, 4 ] => 4.2,
    [ 2, 5 ] => 5.5,
    [ 3, 4 ] => 2.5,
    [ 3, 5 ] => 4.0,
    [ 4, 5 ] => 2.5
  }.freeze

  # Precomputed ordered finger combinations per chord size (1..5) for right hand.
  RH_CANDIDATES = (1..5).to_h { |n| [ n, (1..5).to_a.combination(n).to_a.freeze ] }.freeze

  # Precomputed ordered finger combinations per chord size (1..5) for left hand.
  LH_CANDIDATES = (1..5).to_h { |n| [ n, [ 5, 4, 3, 2, 1 ].combination(n).to_a.freeze ] }.freeze

  # Maximum simultaneous notes playable by a single human hand.
  MAX_NOTES_PER_HAND = 5

  # Solves ergonomic fingerings across an ordered array of hand +events+.
  #
  # ==== Parameters
  # * +events+ - Array of event hashes containing +"notes"+ (and optional +"fingers"+, +"explicit_fingers"+).
  # * +hand+ - +:rh+ (right hand) or +:lh+ (left hand).
  #
  # ==== Returns
  # A new array of sanitized event hashes with +"notes"+ capped to 5 playable pitches
  # and ergonomically solved +"fingers"+ (each integer in +1..5+), stripped of internal markers.
  def self.solve(events, hand: :rh)
    new(hand: hand).solve(events)
  end

  # Solves coherent cross-measure fingerings for every level (+easy+, +medium+,
  # +original+, +faithful+) and both hands across an entire song's +steps+ array.
  def self.solve_song_steps!(steps)
    return steps unless steps.is_a?(Array) && steps.any?

    %w[easy medium original faithful].each do |level_key|
      %w[lh rh].each do |hand_key|
        hand_sym = hand_key.to_sym
        flat_refs = []
        flat_events = []

        steps.each do |step|
          events = step.dig("levels", level_key, hand_key)
          next unless events.is_a?(Array) && events.any?

          events.each_with_index do |ev, ev_idx|
            flat_refs << [ events, ev_idx ]
            flat_events << ev
          end
        end

        next if flat_events.empty?

        solved = solve(flat_events, hand: hand_sym)
        flat_refs.each_with_index do |(target_arr, ev_idx), flat_idx|
          target_arr[ev_idx] = solved[flat_idx]
        end
      end
    end

    steps
  end

  # Reduces an array of sorted pitch identifiers to at most 5 playable notes,
  # preserving the outer bass/melody pitches and balanced inner chord tones.
  def self.cap_playable_notes(notes, explicit_fingers = nil)
    n_list = Array(notes).map(&:to_s)
    return [ n_list, explicit_fingers ] if n_list.size <= MAX_NOTES_PER_HAND

    # Preserve lowest (0) and highest (-1) notes and sample 3 interior notes evenly.
    last_idx = n_list.size - 1
    selected_indices = [
      0,
      (last_idx * 0.25).round,
      (last_idx * 0.5).round,
      (last_idx * 0.75).round,
      last_idx
    ].uniq

    while selected_indices.size < MAX_NOTES_PER_HAND
      missing = (0..last_idx).find { |i| !selected_indices.include?(i) }
      break unless missing

      selected_indices << missing
    end
    selected_indices.sort!

    capped_notes = selected_indices.map { |i| n_list[i] }
    capped_fingers = explicit_fingers.is_a?(Array) ? selected_indices.map { |i| explicit_fingers[i] } : nil
    [ capped_notes, capped_fingers ]
  end

  # Converts a scientific pitch identifier (e.g. +"C#4"+, +"Bb3"+) into a MIDI note number.
  def self.note_to_midi(note_id)
    m = /\A([A-Ga-g])([#b]?)(-?\d+)\z/.match(note_id.to_s.strip)
    return 60 unless m

    step_offset = STEP_OFFSETS.fetch(m[1].upcase, 0)
    alter = m[2] == "#" ? 1 : (m[2] == "b" ? -1 : 0)
    octave = m[3].to_i
    ((octave + 1) * 12) + step_offset + alter
  end

  # Initializes a solver for the specified +hand+ (+:rh+ or +:lh+).
  def initialize(hand: :rh)
    @hand = hand.to_sym == :lh ? :lh : :rh
  end

  # Executes Viterbi dynamic programming across +events+ and returns updated copies.
  def solve(events)
    list = Array(events)
    return [] if list.empty?

    prepared = list.map { |ev| prepare_event(ev) }
    candidate_sets = prepared.map { |item| candidates_for(item) }

    # Viterbi forward pass: track minimum cumulative cost and backpointer per state.
    dp_costs = []
    backpointers = []

    first_midis = prepared[0][:midis]
    first_costs = candidate_sets[0].map do |fingers|
      unary_cost(first_midis, fingers) + initial_prior(first_midis, fingers)
    end
    dp_costs << first_costs
    backpointers << Array.new(candidate_sets[0].size, -1)

    (1...prepared.size).each do |t|
      prev_midis = prepared[t - 1][:midis]
      curr_midis = prepared[t][:midis]
      prev_cands = candidate_sets[t - 1]
      curr_cands = candidate_sets[t]
      prev_dp = dp_costs[t - 1]

      curr_costs = Array.new(curr_cands.size, Float::INFINITY)
      curr_back = Array.new(curr_cands.size, 0)

      curr_cands.each_with_index do |curr_f, j|
        u_cost = unary_cost(curr_midis, curr_f)
        best_cost = Float::INFINITY
        best_prev = 0

        prev_cands.each_with_index do |prev_f, i|
          total = prev_dp[i] + transition_cost(prev_midis, prev_f, curr_midis, curr_f) + u_cost
          if total < best_cost
            best_cost = total
            best_prev = i
          end
        end

        curr_costs[j] = best_cost
        curr_back[j] = best_prev
      end

      dp_costs << curr_costs
      backpointers << curr_back
    end

    # Backtrack optimal state sequence from the minimum-cost final state.
    chosen_indices = Array.new(prepared.size, 0)
    last_row = dp_costs.last
    chosen_indices[-1] = last_row.each_with_index.min_by { |cost, _idx| cost }.last

    (prepared.size - 2).downto(0) do |t|
      chosen_indices[t] = backpointers[t + 1][chosen_indices[t + 1]]
    end

    prepared.each_with_index.map do |item, idx|
      ev = item[:clean_event]
      ev["notes"] = item[:notes]
      ev["fingers"] = candidate_sets[idx][chosen_indices[idx]].dup
      ev
    end
  end

  private

  def prepare_event(raw_ev)
    h = raw_ev.deep_stringify_keys
    explicit_flag = !!h.delete("explicit_fingers")
    raw_notes = Array(h["notes"]).map(&:to_s).reject(&:empty?)
    raw_notes = [ @hand == :lh ? "C3" : "C4" ] if raw_notes.empty?
    raw_fingers = Array(h["fingers"]).map(&:to_i)

    # Sort notes low-to-high by MIDI while keeping explicit finger alignment intact.
    paired = raw_notes.each_with_index.map do |n, idx|
      [ self.class.note_to_midi(n), n, raw_fingers[idx] ]
    end
    paired = paired.uniq { |p| p[1] }.sort_by { |p| p[0] }

    notes = paired.map { |p| p[1] }
    fingers = paired.map { |p| p[2] }
    notes, fingers = self.class.cap_playable_notes(notes, fingers)
    midis = notes.map { |n| self.class.note_to_midi(n) }

    valid_explicit = explicit_flag &&
                     fingers.is_a?(Array) &&
                     fingers.size == notes.size &&
                     fingers.all? { |f| f.is_a?(Integer) && f.between?(1, 5) }

    {
      clean_event: h,
      notes: notes,
      midis: midis,
      explicit_fingers: valid_explicit ? fingers : nil
    }
  end

  def candidates_for(item)
    return [ item[:explicit_fingers] ] if item[:explicit_fingers]

    size = item[:notes].size.clamp(1, MAX_NOTES_PER_HAND)
    @hand == :lh ? LH_CANDIDATES[size] : RH_CANDIDATES[size]
  end

  def key_x(midi)
    (((midi / 12) - 1) * 7.0) + KEY_X_OFFSETS[midi % 12]
  end

  def black_key?(midi)
    BLACK_KEY_PCS.include?(midi % 12)
  end

  def initial_prior(midis, fingers)
    return 0.0 if midis.size > 1

    f = fingers[0]
    if @hand == :rh
      f == 1 && !black_key?(midis[0]) ? -0.15 : 0.0
    else
      f == 5 && !black_key?(midis[0]) ? -0.15 : 0.0
    end
  end

  def unary_cost(midis, fingers)
    cost = 0.0
    is_chord = midis.size > 1
    outer_span = is_chord ? (key_x(midis.last) - key_x(midis.first)) : 0.0

    midis.each_with_index do |midi, idx|
      f = fingers[idx]
      if black_key?(midi)
        if f == 1
          cost += (is_chord && outer_span >= 5.0) ? 1.5 : 5.5
        elsif f == 5
          cost += is_chord ? 0.6 : 2.2
        end
      end

      # Mild preference for stronger, balanced fingers in single-note melodies.
      unless is_chord
        cost += 0.25 if f == 4
        cost += 0.45 if f == 5 && @hand == :rh
        cost += 0.20 if f == 1 && @hand == :lh
      end
    end

    if is_chord
      cost += chord_internal_cost(midis, fingers, outer_span)
    end

    cost
  end

  def chord_internal_cost(midis, fingers, outer_span)
    cost = 0.0

    (0...(midis.size - 1)).each do |i|
      ((i + 1)...midis.size).each do |j|
        dx = key_x(midis[j]) - key_x(midis[i])
        pair = [ fingers[i], fingers[j] ].minmax
        ideal = PAIR_IDEAL_SPAN[pair]
        min_s = PAIR_MIN_SPAN[pair]
        max_s = PAIR_MAX_SPAN[pair]

        cost += (dx - ideal).abs * 0.7
        cost += (dx - max_s) * 14.0 if dx > max_s
        cost += (min_s - dx) * 10.0 if dx < min_s
      end
    end

    # Classical triad grips ([1,3,5] RH / [5,3,1] LH) and 5th-to-octave dyads ([1,5] / [5,1]).
    if midis.size == 3 && outer_span <= 5.5
      standard_triad = @hand == :lh ? [ 5, 3, 1 ] : [ 1, 3, 5 ]
      cost -= 1.4 if fingers == standard_triad
    elsif midis.size == 2 && outer_span >= 3.8
      standard_dyad = @hand == :lh ? [ 5, 1 ] : [ 1, 5 ]
      cost -= 1.5 if fingers == standard_dyad
    end

    cost
  end

  def transition_cost(prev_midis, prev_fingers, curr_midis, curr_fingers)
    if prev_midis.size == 1 && curr_midis.size == 1
      single_transition_cost(prev_midis[0], prev_fingers[0], curr_midis[0], curr_fingers[0])
    else
      chord_transition_cost(prev_midis, prev_fingers, curr_midis, curr_fingers)
    end
  end

  def single_transition_cost(m1, f1, m2, f2)
    # Repeated identical pitch: strongly prefer keeping the same finger.
    if m1 == m2
      return f1 == f2 ? 0.05 : 2.2
    end

    # Moving to a different pitch with the exact same finger is unnatural in legato playing.
    sign = @hand == :lh ? -1.0 : 1.0
    dx = (key_x(m2) - key_x(m1)) * sign
    dist = dx.abs

    return 9.5 + (dist * 0.8) if f1 == f2

    # Very wide leap (> octave): the hand lifts and resets rather than stretching.
    return 4.0 + ((dist - 7.5) * 0.35) if dist > 7.5

    # Natural directional movement (RH ascending -> higher finger; LH ascending -> lower finger).
    if (dx > 0 && f2 > f1) || (dx < 0 && f2 < f1)
      pair = [ f1, f2 ].minmax
      ideal = PAIR_IDEAL_SPAN[pair]
      min_s = PAIR_MIN_SPAN[pair]
      max_s = PAIR_MAX_SPAN[pair]

      cost = (dist - ideal).abs * 0.85
      cost += (dist - max_s) * 9.0 if dist > max_s
      cost += (min_s - dist) * 4.5 if dist < min_s
      cost -= 0.25 if dist <= 1.6 && (f2 - f1).abs == 1
      return [ cost, 0.0 ].max
    end

    # Thumb-under crossing (e.g. RH ascending 3->1 or 4->1; LH descending 3->1 or 4->1).
    if dx > 0 && f2 == 1 && [ 2, 3, 4 ].include?(f1)
      cost = 2.0 + ((dist - 1.1).abs * 1.3)
      cost -= 0.35 if f1 == 3
      cost -= 0.20 if f1 == 4
      cost += 0.60 if f1 == 2
      cost += 4.5 if black_key?(m2)
      cost += (dist - 3.0) * 6.0 if dist > 3.0
      return cost
    end

    # Finger-over-thumb crossing (e.g. RH descending 1->3 or 1->4; LH ascending 1->3 or 1->4).
    if dx < 0 && f1 == 1 && [ 2, 3, 4 ].include?(f2)
      cost = 2.0 + ((dist - 1.1).abs * 1.3)
      cost -= 0.35 if f2 == 3
      cost -= 0.20 if f2 == 4
      cost += 0.60 if f2 == 2
      cost += 4.0 if black_key?(m1)
      cost += (dist - 3.0) * 6.0 if dist > 3.0
      return cost
    end

    # Awkward non-thumb crossing (e.g. 4->2 going up in RH or 5->1 thumb-under).
    12.5 + (dist * 1.5)
  end

  def chord_transition_cost(prev_midis, prev_fingers, curr_midis, curr_fingers)
    prev_anchor = implied_thumb_position(prev_midis, prev_fingers)
    curr_anchor = implied_thumb_position(curr_midis, curr_fingers)
    shift = (curr_anchor - prev_anchor).abs

    cost = shift * 0.85

    # Penalize reusing the exact same finger on a closely neighboring different pitch
    # only when transitioning between a single-note melody and a chord (parallel chords
    # naturally shift the full hand together using the same grip).
    if prev_midis.size == 1 || curr_midis.size == 1
      prev_pairs = prev_midis.zip(prev_fingers)
      curr_pairs = curr_midis.zip(curr_fingers)
      prev_pairs.each do |pm, pf|
        curr_pairs.each do |cm, cf|
          if pf == cf && pm != cm && (cm - pm).abs <= 4
            cost += 1.8
          end
        end
      end
    end

    cost
  end

  def implied_thumb_position(midis, fingers)
    sign = @hand == :lh ? -1.0 : 1.0
    total = 0.0
    midis.each_with_index do |m, idx|
      total += key_x(m) - (sign * FINGER_ANCHOR_OFFSET[fingers[idx]])
    end
    total / midis.size
  end
end
