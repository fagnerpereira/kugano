require "test_helper"

module Songs
  module Parsers
    class MidiParserTest < ActiveSupport::TestCase
      # Builds a minimal Format 0 Standard MIDI File in memory:
      # PPQN = 96, Tempo = 120 BPM, 1 measure of 4/4:
      # LH: C3 (MIDI 48) from tick 0 to 384 (16 sixteenth-ticks)
      # RH: C4+E4+G4 (MIDI 60, 64, 67) from tick 0 to 192 (8 sixteenth-ticks), then A4 (MIDI 69) from 192 to 384
      def sample_midi_bytes
        track_events = +""
        # Tempo meta event at delta 0: 500_000 us/quarter (120 BPM)
        track_events << "\x00\xFF\x51\x03\x07\xA1\x20".b
        # Note On at delta 0: C3(48), C4(60), E4(64), G4(67) velocity 90
        track_events << "\x00\x90\x30\x5A".b
        track_events << "\x00\x90\x3C\x5A".b
        track_events << "\x00\x90\x40\x5A".b
        track_events << "\x00\x90\x43\x5A".b
        # Note Off at delta 192 (0x81 0x40 in VLQ) for C4, E4, G4
        track_events << "\x81\x40\x80\x3C\x00".b
        track_events << "\x00\x80\x40\x00".b
        track_events << "\x00\x80\x43\x00".b
        # Note On at delta 0 for A4 (69)
        track_events << "\x00\x90\x45\x5A".b
        # Note Off at delta 192 (0x81 0x40) for A4 and C3
        track_events << "\x81\x40\x80\x45\x00".b
        track_events << "\x00\x80\x30\x00".b
        # End of Track
        track_events << "\x00\xFF\x2F\x00".b

        header = "MThd".b + [ 6, 0, 1, 96 ].pack("Nn3")
        track = "MTrk".b + [ track_events.bytesize ].pack("N") + track_events
        header + track
      end

      test "deterministically parses binary MIDI into valid SongSchema with LH/RH split and 4 connected levels" do
        payload = Songs::Parsers::MidiParser.parse(
          sample_midi_bytes,
          slug: "midi-etude",
          title: "MIDI Etude"
        )

        validation = Songs::SchemaValidator.validate(payload)
        assert validation.valid?, "MIDI payload failed validation: #{validation.errors.join(', ')}"

        assert_equal "midi-etude", payload["slug"]
        assert_equal 120, payload.dig("meta", "defaultBpm")
        assert_equal "midi", payload.dig("meta", "sourceType")
        assert_equal 1, payload["steps"].size

        step1 = payload["steps"].first
        orig = step1.dig("levels", "original")
        assert_equal [ "C3" ], orig["lh"].first["notes"]
        assert_equal 16, orig["lh"].first["dur"]

        assert_equal [ "C4", "E4", "G4" ], orig["rh"][0]["notes"]
        assert_equal 0, orig["rh"][0]["tick"]
        assert_equal 8, orig["rh"][0]["dur"]

        assert_equal [ "A4" ], orig["rh"][1]["notes"]
        assert_equal 8, orig["rh"][1]["tick"]
        assert_equal 8, orig["rh"][1]["dur"]
      end
    end
  end
end
