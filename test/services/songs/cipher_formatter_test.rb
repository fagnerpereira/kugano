require "test_helper"

module Songs
  class CipherFormatterTest < ActiveSupport::TestCase
    test "converts MIDI numbers to canonical sharp cipher IDs" do
      assert_equal "C2", Songs::CipherFormatter.midi_to_id(36)
      assert_equal "D2", Songs::CipherFormatter.midi_to_id(38)
      assert_equal "C4", Songs::CipherFormatter.midi_to_id(60)
      assert_equal "F#4", Songs::CipherFormatter.midi_to_id(66)
      assert_equal "A#4", Songs::CipherFormatter.midi_to_id(70)
      assert_equal "C6", Songs::CipherFormatter.midi_to_id(84)
    end

    test "converts canonical cipher IDs back to MIDI numbers" do
      assert_equal 36, Songs::CipherFormatter.id_to_midi("C2")
      assert_equal 60, Songs::CipherFormatter.id_to_midi("C4")
      assert_equal 66, Songs::CipherFormatter.id_to_midi("F#4")
      assert_equal 70, Songs::CipherFormatter.id_to_midi("A#4")
      assert_equal 70, Songs::CipherFormatter.id_to_midi("Bb4")
    end

    test "formats contextual enharmonic flats identically to displayCipher" do
      assert_equal "A#4", Songs::CipherFormatter.display_cipher("A#4", "D → Daug")
      assert_equal "Bb4", Songs::CipherFormatter.display_cipher("A#4", "G → Gm → A")
      assert_equal "Eb5", Songs::CipherFormatter.display_cipher("D#5", "Eb → Bb")
      assert_equal "Ab4", Songs::CipherFormatter.display_cipher("G#4", "Ab → Adim7")
    end
  end
end
