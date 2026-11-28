require "test_helper"

class PianoFingeringSolverTest < ActiveSupport::TestCase
  test "assigns ascending scale fingerings without repeating finger 1 on every note" do
    scale_events = %w[C4 D4 E4 F4 G4 A4 B4 C5].each_with_index.map do |note, idx|
      { "tick" => idx * 2, "dur" => 2, "notes" => [ note ] }
    end

    solved = PianoFingeringSolver.solve(scale_events, hand: :rh)
    fingers = solved.map { |ev| ev["fingers"].first }

    assert_equal 8, fingers.size
    assert(fingers.all? { |f| f.between?(1, 5) })
    assert_operator fingers.uniq.size, :>=, 4, "Expected varied scale fingerings, got #{fingers.inspect}"
    # Never reuse the exact same finger on consecutive different pitches in a scale
    fingers.each_cons(2) do |prev_f, curr_f|
      assert_not_equal prev_f, curr_f, "Consecutive different scale notes should not share finger #{prev_f}: #{fingers.inspect}"
    end
    # Standard RH scale starts on thumb and finishes on pinky (or high finger)
    assert_equal 1, fingers.first
    assert_includes [ 4, 5 ], fingers.last
  end

  test "avoids thumb on black keys in melodic passages like Rocket Man and Sadness and Sorrow" do
    rocket_man_rh = %w[A#4 G4 A#4 G4 A#4 C5 A#4].each_with_index.map do |note, idx|
      { "tick" => idx * 2, "dur" => 2, "notes" => [ note ] }
    end

    solved_rm = PianoFingeringSolver.solve(rocket_man_rh, hand: :rh)
    rm_fingers = solved_rm.map { |ev| ev["fingers"].first }

    assert_operator rm_fingers.uniq.size, :>=, 3, "Expected distinct fingers for A#4/G4/C5 motif, got #{rm_fingers.inspect}"
    # Every A#4 (black key) should avoid thumb (1)
    solved_rm.each do |ev|
      if ev["notes"].first == "A#4"
        assert_not_equal 1, ev["fingers"].first, "Thumb should avoid black key A#4 in #{solved_rm.map { |e| [ e['notes'].first, e['fingers'].first ] }}"
      end
    end

    sadness_rh = %w[F#5 E5 B4 B4 B4 E5 G5 A5].each_with_index.map do |note, idx|
      { "tick" => idx * 2, "dur" => 2, "notes" => [ note ] }
    end

    solved_sad = PianoFingeringSolver.solve(sadness_rh, hand: :rh)
    sad_fingers = solved_sad.map { |ev| ev["fingers"].first }
    assert_not_equal 1, sad_fingers.first, "Thumb should avoid black key F#5: #{sad_fingers.inspect}"
    assert_operator sad_fingers.uniq.size, :>=, 4, "Expected natural finger variety, got #{sad_fingers.inspect}"
  end

  test "assigns ergonomic descending and ascending left hand arpeggio fingerings" do
    lh_arpeggio = %w[E3 G3 A#3 D4].each_with_index.map do |note, idx|
      { "tick" => idx * 4, "dur" => 4, "notes" => [ note ] }
    end

    solved = PianoFingeringSolver.solve(lh_arpeggio, hand: :lh)
    fingers = solved.map { |ev| ev["fingers"].first }

    assert_equal 4, fingers.size
    # Ascending LH arpeggio should move from pinky toward thumb (strictly decreasing finger numbers)
    assert_operator fingers.first, :>, fingers.last, "LH ascending arpeggio should go pinky->thumb, got #{fingers.inspect}"
    assert_operator fingers.uniq.size, :>=, 3, "LH arpeggio must not be all 5s: #{fingers.inspect}"
  end

  test "assigns valid ordered fingers for multi-note chords in both hands" do
    rh_chords = [
      { "tick" => 0, "dur" => 8, "notes" => %w[D4 F#4 A4 D5] },
      { "tick" => 8, "dur" => 8, "notes" => %w[C4 E4 G4] }
    ]
    lh_chords = [
      { "tick" => 0, "dur" => 8, "notes" => %w[G3 A#3 D4] },
      { "tick" => 8, "dur" => 8, "notes" => %w[C3 G3] }
    ]

    solved_rh = PianoFingeringSolver.solve(rh_chords, hand: :rh)
    solved_lh = PianoFingeringSolver.solve(lh_chords, hand: :lh)

    assert_equal [ 1, 2, 3, 5 ], solved_rh[0]["fingers"]
    assert_equal [ 1, 3, 5 ], solved_rh[1]["fingers"]
    assert_equal [ 5, 3, 1 ], solved_lh[0]["fingers"]
    assert_equal [ 5, 1 ], solved_lh[1]["fingers"]
  end

  test "preserves explicit author fingerings while solving surrounding events smoothly" do
    events = [
      { "tick" => 0, "dur" => 4, "notes" => [ "C4" ], "fingers" => [ 2 ], "explicit_fingers" => true },
      { "tick" => 4, "dur" => 4, "notes" => [ "D4" ] },
      { "tick" => 8, "dur" => 4, "notes" => [ "E4" ] }
    ]

    solved = PianoFingeringSolver.solve(events, hand: :rh)
    assert_equal [ 2 ], solved[0]["fingers"]
    assert_equal [ 3 ], solved[1]["fingers"]
    assert_equal [ 4 ], solved[2]["fingers"]
    assert_nil solved[0]["explicit_fingers"], "Internal marker should not leak into SongSchema events"
  end

  test "caps events exceeding 5 simultaneous notes to 5 playable notes with matching fingers" do
    dense = [
      { "tick" => 0, "dur" => 16, "notes" => %w[C4 D4 E4 G4 A4 B4 C5] }
    ]

    solved = PianoFingeringSolver.solve(dense, hand: :rh)
    assert_equal 5, solved[0]["notes"].size
    assert_equal 5, solved[0]["fingers"].size
    assert_equal [ 1, 2, 3, 4, 5 ], solved[0]["fingers"]
  end
end
