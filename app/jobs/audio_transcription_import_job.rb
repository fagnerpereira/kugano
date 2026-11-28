require "json"
require "open3"

# = Overview
#
# Background ActiveJob (executed by Solid Queue on the dedicated +:omr+ queue) that
# transcribes an uploaded audio file (including browser microphone recordings) or
# a YouTube URL into a deterministic 4-level Piano Studio +SongSchema+ payload.
#
# Pipeline steps (100% free & open-source, zero paid APIs):
# 1. If a URL is provided, downloads audio via latest +yt-dlp+ (with JS runtime for
#    YouTube EJS challenges and +--no-playlist+) and extracts video title/uploader.
# 2. Runs the configured audio transcriber (+BASIC_PITCH_BIN+, which runs Spotify
#    +basic-pitch+ on ONNX CPU + +librosa+ beat/key/chord recognition).
# 3. Feeds the generated MIDI + optional +.analysis.json+ chord/tempo sidecar into
#    {MusicImporterService}, which builds 4 connected progressive levels and solves
#    ergonomic piano fingerings via {PianoFingeringSolver}.
class AudioTranscriptionImportJob < ApplicationJob
  queue_as :omr

  # Default timeout (in seconds) for YouTube audio download via yt-dlp.
  DOWNLOAD_TIMEOUT_SECONDS = 120

  # Default timeout (in seconds) for polyphonic audio transcription.
  TRANSCRIPTION_TIMEOUT_SECONDS = 240

  # Placeholder title assigned by {SongsController} when the user leaves the title blank.
  DEFAULT_PLACEHOLDER_TITLE = "Partitura Importada".freeze

  def perform(song_id)
    song = Song.find_by(id: song_id)
    return unless song

    transcriber_bin = ENV.fetch("BASIC_PITCH_BIN", "basic-pitch")
    unless executable_available?(transcriber_bin)
      raise StandardError, "CLI de transcrição de áudio (basic-pitch) não encontrado no ambiente."
    end

    resolved_title = song.title
    resolved_artist = song.artist

    payload = Dir.mktmpdir("audio_transcription_job") do |dir|
      audio_path, yt_meta = prepare_audio_file(song, dir)
      if yt_meta.present?
        resolved_title = yt_meta["title"].to_s.strip if resolved_title.blank? || resolved_title == DEFAULT_PLACEHOLDER_TITLE
        resolved_artist = yt_meta["artist"].to_s.strip if resolved_artist.blank? || resolved_artist == "Importado"
      end

      timeout_sec = ENV.fetch("AUDIO_TRANSCRIPTION_TIMEOUT", TRANSCRIPTION_TIMEOUT_SECONDS).to_f
      out, err, status = run_command_with_timeout([ transcriber_bin, dir, audio_path ], timeout: timeout_sec, label: "Transcrição de áudio")
      unless status.success?
        detail = err.to_s.strip.presence || out.to_s.strip.presence || "erro desconhecido"
        raise StandardError, "Falha na transcrição de áudio: #{detail}"
      end

      transcribed_file = Dir.glob(File.join(dir, "**", "*.{mid,midi,musicxml,xml,mxl}")).sort.first
      raise StandardError, "Transcrição não gerou arquivo MIDI ou MusicXML" unless transcribed_file

      analysis = load_analysis_sidecar(dir)

      imported = MusicImporterService.call(
        content: File.binread(transcribed_file),
        filename: File.basename(transcribed_file),
        slug: song.slug,
        title: resolved_title,
        artist: resolved_artist,
        bpm_override: analysis["bpm"],
        key_override: analysis["key"],
        chord_overrides: analysis["chords"],
        time_sig_override: analysis["timeSignature"]
      )
      imported["meta"]["sourceType"] = "audio_youtube"
      imported
    end

    song.update!(
      title: resolved_title.presence || song.title,
      artist: resolved_artist.presence || song.artist,
      status: "ready",
      error_message: nil,
      payload: payload
    )
  rescue StandardError => e
    song&.update(status: "failed", error_message: e.message)
  end

  private

  def prepare_audio_file(song, dir)
    if song.source_file.attached?
      ext = File.extname(song.source_file.filename.to_s).presence || ".wav"
      path = File.join(dir, "input#{ext}")
      File.binwrite(path, song.source_file.download)
      return [ path, {} ]
    end

    raise ArgumentError, "Arquivo de áudio ou URL ausente" if song.source_url.blank?

    yt_bin = ENV.fetch("YTDLP_BIN", "yt-dlp")
    unless executable_available?(yt_bin)
      raise StandardError, "yt-dlp não encontrado para baixar áudio da URL informada."
    end

    download_youtube_audio(yt_bin, song.source_url, dir)
  end

  def download_youtube_audio(yt_bin, source_url, dir)
    out_template = File.join(dir, "yt_audio.%(ext)s")
    base_cmd = build_ytdlp_command(yt_bin, out_template, source_url)
    timeout_sec = ENV.fetch("YTDLP_TIMEOUT", DOWNLOAD_TIMEOUT_SECONDS).to_f

    out, err, status = run_command_with_timeout(base_cmd, timeout: timeout_sec, label: "Download YouTube")

    unless status.success?
      combined = "#{err}\n#{out}"
      if youtube_rate_limited_or_bot_gated?(combined)
        raise StandardError, youtube_gate_error_message
      end

      # Automatic fallback using alternate YouTube mobile/VR clients for format/SABR issues.
      fallback_cmd = build_ytdlp_command(yt_bin, out_template, source_url, extractor_args: "youtube:player_client=android_vr,ios,web")
      f_out, f_err, f_status = run_command_with_timeout(fallback_cmd, timeout: timeout_sec, label: "Download YouTube (fallback)")
      if f_status.success?
        out, err, status = f_out, f_err, f_status
      else
        f_combined = "#{f_err}\n#{f_out}\n#{combined}"
        raise StandardError, youtube_gate_error_message if youtube_rate_limited_or_bot_gated?(f_combined)

        detail = f_err.to_s.strip.presence || err.to_s.strip.presence || out.to_s.strip.presence || "erro desconhecido"
        raise StandardError, "Falha ao baixar áudio da URL: #{detail}"
      end
    end

    audio_file = Dir.glob(File.join(dir, "yt_audio.*")).reject { |f| f.end_with?(".json", ".part") }.first
    raise StandardError, "Áudio baixado não encontrado" unless audio_file

    meta = load_ytdlp_metadata(dir)
    [ audio_file, meta ]
  end

  def youtube_rate_limited_or_bot_gated?(output)
    output.match?(/Sign in to confirm you.?re not a bot|HTTP Error 429|Too Many Requests/i)
  end

  def youtube_gate_error_message
    "O YouTube bloqueou temporariamente este IP (HTTP 429 / verificação de login). " \
      "Use o botão '🎙️ Gravar Microfone' para captar a música tocando agora, ou forneça seus cookies " \
      "autenticados em YTDLP_COOKIES_FILE (/rails/storage/youtube_cookies.txt)."
  end

  def build_ytdlp_command(yt_bin, out_template, source_url, extractor_args: nil)
    cmd = [
      yt_bin,
      "--no-playlist",
      "--write-info-json",
      "--socket-timeout", "30",
      "--retries", "3",
      "-f", "bestaudio/best",
      "-x",
      "--audio-format", "wav",
      "--audio-quality", "0"
    ]

    js_runtime = ENV["YTDLP_JS_RUNTIME"].to_s.strip
    cmd.push("--js-runtimes", js_runtime) if js_runtime.present?

    cookies_file = ENV["YTDLP_COOKIES_FILE"].to_s.strip
    cmd.push("--cookies", cookies_file) if cookies_file.present? && File.exist?(cookies_file)

    cmd.push("--extractor-args", extractor_args) if extractor_args.present?
    cmd.push("-o", out_template, source_url)
    cmd
  end

  def load_ytdlp_metadata(dir)
    info_path = Dir.glob(File.join(dir, "yt_audio*.info.json")).first
    return {} unless info_path && File.exist?(info_path)

    parsed = JSON.parse(File.read(info_path))
    {
      "title" => parsed["track"].presence || parsed["title"].presence,
      "artist" => parsed["artist"].presence || parsed["uploader"].presence || parsed["channel"].presence
    }.compact
  rescue JSON::ParserError, Errno::ENOENT
    {}
  end

  def load_analysis_sidecar(dir)
    sidecar = Dir.glob(File.join(dir, "**", "*.analysis.json")).first
    return {} unless sidecar && File.exist?(sidecar)

    JSON.parse(File.read(sidecar))
  rescue JSON::ParserError, Errno::ENOENT
    {}
  end

  def run_command_with_timeout(cmd, timeout:, label:)
    Open3.popen3(*cmd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      out_reader = Thread.new { stdout.read.to_s }
      err_reader = Thread.new { stderr.read.to_s }

      unless wait_thr.join(timeout)
        terminate_process_group(wait_thr.pid)
        out_reader.join(1)
        err_reader.join(1)
        raise StandardError, "#{label} excedeu o tempo limite de #{timeout.to_i}s"
      end

      [ out_reader.value, err_reader.value, wait_thr.value ]
    end
  end

  def terminate_process_group(pid)
    pgid = -pid
    Process.kill("TERM", pgid)
    sleep 0.2
    Process.kill("KILL", pgid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def executable_available?(bin)
    File.executable?(bin) || system("which", bin, out: File::NULL, err: File::NULL)
  end
end
