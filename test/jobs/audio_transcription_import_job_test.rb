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

  test "applies sidecar analysis.json chords/tempo/key and downloads YouTube audio with JS runtime flags" do
    track_events = +"\x00\xFF\x51\x03\x07\xA1\x20\x00\x90\x32\x5A\x00\x90\x3E\x5A\x00\x90\x42\x5A\x81\x40\x80\x3E\x00\x00\x80\x42\x00\x00\x80\x32\x00\x00\xFF\x2F\x00".b
    midi_bytes = "MThd".b + [ 6, 0, 1, 96 ].pack("Nn3") + "MTrk".b + [ track_events.bytesize ].pack("N") + track_events

    song = Song.create!(
      slug: "yt-todo-no",
      title: "Partitura Importada",
      source_type: "audio_youtube",
      source_url: "https://www.youtube.com/watch?v=SeDyYtIuhsA",
      status: "processing",
      payload: {}
    )

    Dir.mktmpdir("fake_yt_pipeline") do |bin_dir|
      midi_template = File.join(bin_dir, "template.mid")
      File.binwrite(midi_template, midi_bytes)

      yt_args_file = File.join(bin_dir, "yt_args.txt")
      fake_ytdlp = File.join(bin_dir, "fake_ytdlp")
      File.write(fake_ytdlp, <<~SH)
        #!/usr/bin/env bash
        printf '%s\\n' "$@" > "#{yt_args_file}"
        out_tpl=""
        while [[ $# -gt 0 ]]; do
          if [[ "$1" == "-o" ]]; then
            out_tpl="$2"
            shift 2
          else
            shift
          fi
        done
        out_dir="$(dirname "$out_tpl")"
        printf 'RIFF_WAV' > "$out_dir/yt_audio.wav"
        printf '{"title":"Todo No (Ao Vivo)","uploader":"Dingo Bells"}' > "$out_dir/yt_audio.info.json"
      SH
      File.chmod(0o755, fake_ytdlp)

      fake_transcriber = File.join(bin_dir, "fake_basic_pitch")
      File.write(fake_transcriber, <<~SH)
        #!/usr/bin/env bash
        out_dir="$1"
        cp "#{midi_template}" "$out_dir/transcribed.mid"
        cat << 'JSON' > "$out_dir/transcribed.analysis.json"
        {"bpm": 88, "key": "D", "timeSignature": "4/4", "chords": ["D", "Bm"]}
        JSON
      SH
      File.chmod(0o755, fake_transcriber)

      prev_bp = ENV["BASIC_PITCH_BIN"]
      prev_yt = ENV["YTDLP_BIN"]
      prev_js = ENV["YTDLP_JS_RUNTIME"]
      ENV["BASIC_PITCH_BIN"] = fake_transcriber
      ENV["YTDLP_BIN"] = fake_ytdlp
      ENV["YTDLP_JS_RUNTIME"] = "bun"
      begin
        AudioTranscriptionImportJob.perform_now(song.id)
      ensure
        ENV["BASIC_PITCH_BIN"] = prev_bp
        ENV["YTDLP_BIN"] = prev_yt
        ENV["YTDLP_JS_RUNTIME"] = prev_js
      end

      yt_args = File.readlines(yt_args_file, chomp: true)
      assert_includes yt_args, "--no-playlist"
      assert_includes yt_args, "--js-runtimes"
      assert_includes yt_args, "bun"
    end

    song.reload
    assert_equal "ready", song.status
    assert_equal "Todo No (Ao Vivo)", song.title
    assert_equal "Dingo Bells", song.artist
    assert_equal 88, song.payload.dig("meta", "defaultBpm")
    assert_equal "D", song.payload.dig("meta", "key")
    assert_equal "D", song.payload.dig("steps", 0, "levels", "easy", "chord")
    assert_equal [ "D4", "F#4", "A4" ], song.payload.dig("steps", 0, "levels", "easy", "rh", 0, "notes")
    assert Songs::SchemaValidator.validate(song.payload).valid?
  end

  test "fails fast with actionable message on YouTube 429 or bot sign-in gate and passes cookies when configured" do
    song = Song.create!(
      slug: "yt-rate-limited",
      title: "Rate Limited Song",
      source_type: "audio_youtube",
      source_url: "https://www.youtube.com/watch?v=SeDyYtIuhsA",
      status: "processing",
      payload: {}
    )

    Dir.mktmpdir("fake_yt_429") do |bin_dir|
      calls_file = File.join(bin_dir, "calls.txt")
      args_file = File.join(bin_dir, "args.txt")
      cookies_file = File.join(bin_dir, "cookies.txt")
      File.write(cookies_file, "# Netscape HTTP Cookie File\n")

      fake_ytdlp = File.join(bin_dir, "fake_ytdlp")
      File.write(fake_ytdlp, <<~SH)
        #!/usr/bin/env bash
        echo "call" >> "#{calls_file}"
        printf '%s\\n' "$@" > "#{args_file}"
        echo "ERROR: [youtube] SeDyYtIuhsA: Sign in to confirm you're not a bot. HTTP Error 429: Too Many Requests" >&2
        exit 1
      SH
      File.chmod(0o755, fake_ytdlp)

      fake_transcriber = File.join(bin_dir, "fake_basic_pitch")
      File.write(fake_transcriber, "#!/usr/bin/env bash\nexit 0\n")
      File.chmod(0o755, fake_transcriber)

      prev_bp = ENV["BASIC_PITCH_BIN"]
      prev_yt = ENV["YTDLP_BIN"]
      prev_cookies = ENV["YTDLP_COOKIES_FILE"]
      ENV["BASIC_PITCH_BIN"] = fake_transcriber
      ENV["YTDLP_BIN"] = fake_ytdlp
      ENV["YTDLP_COOKIES_FILE"] = cookies_file
      begin
        AudioTranscriptionImportJob.perform_now(song.id)
      ensure
        ENV["BASIC_PITCH_BIN"] = prev_bp
        ENV["YTDLP_BIN"] = prev_yt
        ENV["YTDLP_COOKIES_FILE"] = prev_cookies
      end

      assert_equal 1, File.readlines(calls_file).size, "Should not retry YouTube immediately on 429 / bot-check gate"
      yt_args = File.readlines(args_file, chomp: true)
      assert_includes yt_args, "--cookies"
      assert_includes yt_args, cookies_file
    end

    song.reload
    assert_equal "failed", song.status
    assert_match(/YouTube bloqueou temporariamente|cookies|microfone/i, song.error_message)
  end
end
