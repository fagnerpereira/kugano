require "test_helper"

module Songs
  class LevelConnectorTest < ActiveSupport::TestCase
    test "connects 4 progressive levels inheriting base ticks additively" do
      easy = {
        "chord" => "D", "pedal" => false, "tip" => "Easy tip",
        "lh" => [ { "tick" => 0, "dur" => 16, "notes" => [ "D2" ], "fingers" => [ 5 ] } ],
        "rh" => [
          { "tick" => 0, "dur" => 8, "notes" => [ "D4", "F#4", "A4" ], "fingers" => [ 1, 2, 4 ] },
          { "tick" => 8, "dur" => 8, "notes" => [ "D4", "F#4", "A4" ], "fingers" => [ 1, 2, 4 ] }
        ]
      }
      medium_delta = {
        "chord" => "D", "pedal" => false, "tip" => "Medium tip",
        "lh" => [ { "tick" => 8, "dur" => 8, "notes" => [ "A2" ], "fingers" => [ 2 ] } ],
        "rh" => [
          { "tick" => 4, "dur" => 4, "notes" => [ "D4", "F#4", "A4" ], "fingers" => [ 1, 2, 4 ] },
          { "tick" => 12, "dur" => 4, "notes" => [ "D4", "F#4", "A4" ], "fingers" => [ 1, 2, 4 ] }
        ]
      }
      original_delta = {
        "chord" => "D → Daug", "pedal" => false, "tip" => "Original tip",
        "lh" => [],
        "rh" => [
          { "tick" => 14, "dur" => 2, "notes" => [ "D4", "F#4", "A#4" ], "fingers" => [ 1, 2, 4 ] }
        ]
      }

      connected = Songs::LevelConnector.connect(easy, medium_delta, original_delta)

      assert_equal %w[easy medium original faithful], connected.keys
      # Medium keeps tick 0 from easy and adds tick 8 in LH, plus ticks 4 and 12 in RH
      assert_equal [ 0, 8 ], connected["medium"]["lh"].map { |e| e["tick"] }
      assert_equal [ 0, 4, 8, 12 ], connected["medium"]["rh"].map { |e| e["tick"] }
      # Original keeps medium's ticks and adds tick 14 in RH
      assert_equal [ 0, 4, 8, 12, 14 ], connected["original"]["rh"].map { |e| e["tick"] }
      assert_equal "D → Daug", connected["original"]["chord"]
    end

    test "derives 4 connected levels deterministically from raw imported measure events" do
      lh_orig = [
        { "tick" => 0, "dur" => 4, "notes" => [ "D2", "D3" ], "fingers" => [ 5, 1 ] },
        { "tick" => 4, "dur" => 4, "notes" => [ "A2" ], "fingers" => [ 2 ] },
        { "tick" => 8, "dur" => 4, "notes" => [ "D2" ], "fingers" => [ 5 ] },
        { "tick" => 12, "dur" => 4, "notes" => [ "A2" ], "fingers" => [ 2 ] }
      ]
      rh_orig = [
        { "tick" => 0, "dur" => 2, "notes" => [ "D4", "F#4", "A4", "D5" ], "fingers" => [ 1, 2, 3, 5 ] },
        { "tick" => 2, "dur" => 2, "notes" => [ "F#4" ], "fingers" => [ 2 ] },
        { "tick" => 4, "dur" => 4, "notes" => [ "A4" ], "fingers" => [ 3 ] },
        { "tick" => 8, "dur" => 4, "notes" => [ "D4", "F#4", "A4" ], "fingers" => [ 1, 2, 4 ] },
        { "tick" => 12, "dur" => 4, "notes" => [ "B4" ], "fingers" => [ 5 ] }
      ]

      levels = Songs::LevelConnector.derive_from_score(
        chord: "D",
        pedal: true,
        lh_events: lh_orig,
        rh_events: rh_orig
      )

      assert_equal %w[easy medium original faithful], levels.keys
      # Easy has simplified anchor beats (ticks 0 and 8) with root bass note
      assert_equal [ "D2" ], levels["easy"]["lh"].first["notes"]
      assert(levels["easy"]["rh"].all? { |ev| (ev["tick"] % 4).zero? })
      # Original preserves full polyphony
      assert_equal 4, levels["original"]["rh"].first["notes"].size
    end

    test "assigns deterministic fingers 1..5 when imported events have no fingering" do
      assert_equal [ 5 ], Songs::LevelConnector.assign_fingers([ "D2" ], hand: :lh)
      assert_equal [ 5, 1 ], Songs::LevelConnector.assign_fingers([ "D2", "D3" ], hand: :lh)
      assert_equal [ 1, 2, 4 ], Songs::LevelConnector.assign_fingers([ "D4", "F#4", "A4" ], hand: :rh)
      assert_equal [ 1, 2, 3, 5 ], Songs::LevelConnector.assign_fingers([ "D4", "F#4", "A4", "D5" ], hand: :rh)
    end
  end
end
