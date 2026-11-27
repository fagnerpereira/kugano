require "test_helper"

module Songs
  class SchemaValidatorTest < ActiveSupport::TestCase
    def valid_payload
      {
        "schemaVersion" => "1.0",
        "slug" => "todo-no",
        "meta" => {
          "title" => "Todo Nó — Dingo Bells",
          "artist" => "Dingo Bells",
          "info" => "Tom: D • 76 BPM • 4/4",
          "key" => "D",
          "defaultBpm" => 76,
          "presets" => [ 56, 66, 76 ],
          "timeSignature" => "4/4",
          "ticksPerMeasure" => 16,
          "sourceType" => "native"
        },
        "sections" => [
          { "id" => 1, "name" => "1. Intro" }
        ],
        "steps" => [
          {
            "id" => 1,
            "tag" => "Comp. 1",
            "sectionId" => 1,
            "title" => "Introdução (1/4) — D",
            "lyric" => "Abertura instrumental (0:00)",
            "voice" => [
              { "tick" => 2, "dur" => 3, "note" => "F#4" }
            ],
            "levels" => {
              "easy" => valid_level("D"),
              "medium" => valid_level("D"),
              "original" => valid_level("D → Daug"),
              "faithful" => valid_level("D")
            }
          }
        ]
      }
    end

    def valid_level(chord)
      {
        "chord" => chord,
        "pedal" => false,
        "tip" => "Dica do compasso",
        "lh" => [
          { "tick" => 0, "dur" => 16, "notes" => [ "D2" ], "fingers" => [ 5 ] }
        ],
        "rh" => [
          { "tick" => 0, "dur" => 8, "notes" => [ "D4", "F#4", "A4" ], "fingers" => [ 1, 2, 4 ] }
        ]
      }
    end

    test "accepts a valid SongSchema payload" do
      result = Songs::SchemaValidator.validate(valid_payload)
      assert result.valid?, "Expected payload to be valid, got errors: #{result.errors.join(', ')}"
      assert_empty result.errors
    end

    test "rejects missing required top-level keys" do
      result = Songs::SchemaValidator.validate({ "schemaVersion" => "1.0" })
      assert_not result.valid?
      assert_includes result.errors, "slug ausente ou inválido"
      assert_includes result.errors, "meta ausente"
      assert_includes result.errors, "sections deve conter ao menos 1 seção"
      assert_includes result.errors, "steps deve conter ao menos 1 compasso"
    end

    test "rejects invalid note cipher outside A-G" do
      payload = valid_payload
      payload["steps"][0]["levels"]["easy"]["rh"][0]["notes"] = [ "H4", "F#4", "A4" ]
      result = Songs::SchemaValidator.validate(payload)
      assert_not result.valid?
      assert result.errors.any? { |e| e.include?("H4") }
    end

    test "rejects invalid finger outside 1..5 or mismatched fingers length" do
      payload = valid_payload
      payload["steps"][0]["levels"]["easy"]["rh"][0]["fingers"] = [ 1, 6, 4 ]
      result = Songs::SchemaValidator.validate(payload)
      assert_not result.valid?
      assert result.errors.any? { |e| e.include?("dedilhado") }

      payload2 = valid_payload
      payload2["steps"][0]["levels"]["easy"]["rh"][0]["fingers"] = [ 1, 2 ]
      result2 = Songs::SchemaValidator.validate(payload2)
      assert_not result2.valid?
      assert result2.errors.any? { |e| e.include?("quantidade de dedos") }
    end

    test "rejects missing connected progressive level" do
      payload = valid_payload
      payload["steps"][0]["levels"].delete("faithful")
      result = Songs::SchemaValidator.validate(payload)
      assert_not result.valid?
      assert result.errors.any? { |e| e.include?("faithful") }
    end
  end
end
