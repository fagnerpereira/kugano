require "test_helper"

class ProgressiveLevelGeneratorTest < ActiveSupport::TestCase
  test "assigns deterministic fingers 1..5 for left and right hands" do
    assert_equal [ 5 ], ProgressiveLevelGenerator.assign_fingers([ "D2" ], hand: :lh)
    assert_equal [ 5, 1 ], ProgressiveLevelGenerator.assign_fingers([ "D2", "D3" ], hand: :lh)
    assert_equal [ 1, 2, 4 ], ProgressiveLevelGenerator.assign_fingers([ "D4", "F#4", "A4" ], hand: :rh)
    assert_equal [ 1, 2, 3, 5 ], ProgressiveLevelGenerator.assign_fingers([ "D4", "F#4", "A4", "D5" ], hand: :rh)
  end

  test "generates 4 connected progressive levels where each level reuses the base of the previous one" do
    lh_events = [
      { "tick" => 0, "dur" => 4, "notes" => [ "D2", "D3" ] },
      { "tick" => 4, "dur" => 4, "notes" => [ "A2" ] },
      { "tick" => 8, "dur" => 4, "notes" => [ "D2" ] },
      { "tick" => 12, "dur" => 4, "notes" => [ "A2" ] }
    ]
    rh_events = [
      { "tick" => 0, "dur" => 2, "notes" => [ "D4", "F#4", "A4", "D5" ] },
      { "tick" => 2, "dur" => 2, "notes" => [ "F#4" ] },
      { "tick" => 4, "dur" => 4, "notes" => [ "A4" ] },
      { "tick" => 8, "dur" => 4, "notes" => [ "D4", "F#4", "A4" ] },
      { "tick" => 12, "dur" => 4, "notes" => [ "B4" ] }
    ]

    levels = ProgressiveLevelGenerator.generate(
      chord: "D",
      pedal: true,
      lh_events: lh_events,
      rh_events: rh_events
    )

    assert_equal %w[easy medium original faithful], levels.keys

    # 1. Easy level has anchor ticks (0 and 8) and simple 1..5 fingering
    easy_lh_ticks = levels["easy"]["lh"].map { |e| e["tick"] }
    easy_rh_ticks = levels["easy"]["rh"].map { |e| e["tick"] }
    assert_includes easy_lh_ticks, 0
    assert_includes easy_rh_ticks, 0
    assert_equal [ "D2" ], levels["easy"]["lh"].first["notes"]
    assert_equal [ 5 ], levels["easy"]["lh"].first["fingers"]

    # 2. Medium reuses Easy anchor ticks and adds groove/arpeggio ticks
    med_lh_ticks = levels["medium"]["lh"].map { |e| e["tick"] }
    med_rh_ticks = levels["medium"]["rh"].map { |e| e["tick"] }
    easy_lh_ticks.each { |t| assert_includes med_lh_ticks, t }
    easy_rh_ticks.each { |t| assert_includes med_rh_ticks, t }
    assert_operator med_rh_ticks.size, :>, easy_rh_ticks.size

    # 3. Original reuses Medium ticks and includes full polyphony / subdivisions
    orig_rh_ticks = levels["original"]["rh"].map { |e| e["tick"] }
    med_rh_ticks.each { |t| assert_includes orig_rh_ticks, t }
    assert_equal [ "D4", "F#4", "A4", "D5" ], levels["original"]["rh"].first["notes"]
    assert_equal [ 1, 2, 3, 5 ], levels["original"]["rh"].first["fingers"]

    # 4. Faithful is present with valid fingers 1..5
    assert_equal "D", levels["faithful"]["chord"]
    levels.each_value do |lvl|
      (lvl["lh"] + lvl["rh"]).each do |ev|
        assert_equal ev["notes"].size, ev["fingers"].size
        assert(ev["fingers"].all? { |f| f.between?(1, 5) })
      end
    end
  end
end
