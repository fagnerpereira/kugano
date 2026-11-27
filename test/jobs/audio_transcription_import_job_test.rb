require "test_helper"

class AudioTranscriptionImportJobTest < ActiveJob::TestCase
  test "transcribes audio/YouTube via CLI to MIDI and imports using MusicImporterService" do
    track_events = +"\x00\xFF\x51\x03\x07\xA1\x20\x00\x90\x30\x5A\x00\x90\x3C\x5A\x81\x40\x80\x3C\x00\x00\x80\x30\x00\x00\xFF\x2F\x00".b
    midi_bytes = "MThd".b + [ 6, 0, 1, 96 ].pack("Nn3") + "MTrk".b + [ track_events.bytesize ].pack("N") + track_events

    song = Song.create!(
      slug: "audio-transcribed-song",
      title: "Audio Song",
      source_type: "audio_youtube",
      status: "processing",
      payload: {}
    )
    song.source_file.attach(io: StringIO.new("RIFF_FAKE_WAV"), filename: "audio.wav", content_type: "audio/wav")

    Dir.mktmpdir("fake_transcriber_bin") do |bin_dir|
      midi_template = File.join(bin_dir, "template.mid")
      File.binwrite(midi_template, midi_bytes)

      fake_transcriber = File.join(bin_dir, "fake_basic_pitch")
      File.write(fake_transcriber, <<~SH)
        #!/usr/bin/env bash
        out_dir="$1"
        cp "#{midi_template}" "$out_dir/transcribed.mid"
      SH
      File.chmod(0o755, fake_transcriber)

      prev_env = ENV["BASIC_PITCH_BIN"]
      ENV["BASIC_PITCH_BIN"] = fake_transcriber
      begin
        AudioTranscriptionImportJob.perform_now(song.id)
      ensure
        ENV["BASIC_PITCH_BIN"] = prev_env
      end
    end

    song.reload
    assert_equal "ready", song.status
    assert_equal "audio_youtube", song.payload.dig("meta", "sourceType")
    assert Songs::SchemaValidator.validate(song.payload).valid?
    assert_equal [ "C3" ], song.payload.dig("steps", 0, "levels", "original", "lh", 0, "notes")
    assert_equal [ "C4" ], song.payload.dig("steps", 0, "levels", "original", "rh", 0, "notes")
  end
end
