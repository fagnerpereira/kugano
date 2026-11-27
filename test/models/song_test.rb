require "test_helper"

class SongTest < ActiveSupport::TestCase
  def sample_payload
    {
      "schemaVersion" => "1.0",
      "slug" => "test-song",
      "meta" => {
        "title" => "Test Song",
        "artist" => "Test Artist",
        "info" => "Tom: C • 80 BPM • 4/4",
        "key" => "C",
        "defaultBpm" => 80,
        "presets" => [ 60, 70, 80 ],
        "timeSignature" => "4/4",
        "ticksPerMeasure" => 16,
        "sourceType" => "native"
      },
      "sections" => [ { "id" => 1, "name" => "1. Intro" } ],
      "steps" => [
        {
          "id" => 1,
          "tag" => "Comp. 1",
          "sectionId" => 1,
          "title" => "Intro — C",
          "lyric" => "Instrumental",
          "voice" => [],
          "levels" => {
            "easy" => { "chord" => "C", "pedal" => false, "tip" => "Tip", "lh" => [ { "tick" => 0, "dur" => 16, "notes" => [ "C3" ], "fingers" => [ 5 ] } ], "rh" => [ { "tick" => 0, "dur" => 16, "notes" => [ "C4", "E4", "G4" ], "fingers" => [ 1, 2, 4 ] } ] },
            "medium" => { "chord" => "C", "pedal" => false, "tip" => "Tip", "lh" => [ { "tick" => 0, "dur" => 16, "notes" => [ "C3" ], "fingers" => [ 5 ] } ], "rh" => [ { "tick" => 0, "dur" => 16, "notes" => [ "C4", "E4", "G4" ], "fingers" => [ 1, 2, 4 ] } ] },
            "original" => { "chord" => "C", "pedal" => false, "tip" => "Tip", "lh" => [ { "tick" => 0, "dur" => 16, "notes" => [ "C3" ], "fingers" => [ 5 ] } ], "rh" => [ { "tick" => 0, "dur" => 16, "notes" => [ "C4", "E4", "G4" ], "fingers" => [ 1, 2, 4 ] } ] },
            "faithful" => { "chord" => "C", "pedal" => false, "tip" => "Tip", "lh" => [ { "tick" => 0, "dur" => 16, "notes" => [ "C3" ], "fingers" => [ 5 ] } ], "rh" => [ { "tick" => 0, "dur" => 16, "notes" => [ "C4", "E4", "G4" ], "fingers" => [ 1, 2, 4 ] } ] }
          }
        }
      ]
    }
  end

  test "validates ready song requires valid SongSchema payload" do
    song = Song.new(
      slug: "test-song",
      title: "Test Song",
      source_type: "native",
      status: "ready",
      payload: sample_payload
    )
    assert song.valid?, song.errors.full_messages.join(", ")
  end

  test "rejects ready song with invalid SongSchema payload" do
    song = Song.new(
      slug: "invalid-song",
      title: "Invalid Song",
      source_type: "musicxml",
      status: "ready",
      payload: { "schemaVersion" => "1.0" }
    )
    assert_not song.valid?
    assert song.errors[:payload].any?
  end

  test "allows processing song without payload yet" do
    song = Song.new(
      slug: "importing-song",
      title: "Importing Song",
      source_type: "musicxml",
      status: "processing",
      payload: {}
    )
    assert song.valid?, song.errors.full_messages.join(", ")
  end
end
