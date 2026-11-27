require "open3"

class AudioTranscriptionImportJob < ApplicationJob
  queue_as :omr

  def perform(song_id)
    song = Song.find_by(id: song_id)
    return unless song

    transcriber_bin = ENV.fetch("BASIC_PITCH_BIN", "basic-pitch")
    unless executable_available?(transcriber_bin)
      raise StandardError, "CLI de transcrição de áudio (basic-pitch) não encontrado no ambiente."
    end

    payload = Dir.mktmpdir("audio_transcription_job") do |dir|
      audio_path = prepare_audio_file(song, dir)

      _out, err, status = Open3.capture3(transcriber_bin, dir, audio_path)
      raise StandardError, "Falha na transcrição de áudio: #{err}" unless status.success?

      transcribed_file = Dir.glob(File.join(dir, "**", "*.{mid,midi,musicxml,xml,mxl}")).first
      raise StandardError, "Transcrição não gerou arquivo MIDI ou MusicXML" unless transcribed_file

      imported = MusicImporterService.call(
        content: File.binread(transcribed_file),
        filename: File.basename(transcribed_file),
        slug: song.slug,
        title: song.title,
        artist: song.artist
      )
      imported["meta"]["sourceType"] = "audio_youtube"
      imported
    end

    song.update!(status: "ready", error_message: nil, payload: payload)
  rescue StandardError => e
    song&.update(status: "failed", error_message: e.message)
  end

  private

  def prepare_audio_file(song, dir)
    if song.source_file.attached?
      ext = File.extname(song.source_file.filename.to_s).presence || ".wav"
      path = File.join(dir, "input#{ext}")
      File.binwrite(path, song.source_file.download)
      return path
    end

    raise ArgumentError, "Arquivo de áudio ou URL ausente" if song.source_url.blank?

    yt_bin = ENV.fetch("YTDLP_BIN", "yt-dlp")
    unless executable_available?(yt_bin)
      raise StandardError, "yt-dlp não encontrado para baixar áudio da URL informada."
    end

    out_template = File.join(dir, "yt_audio.%(ext)s")
    _out, err, status = Open3.capture3(yt_bin, "-x", "--audio-format", "wav", "-o", out_template, song.source_url)
    raise StandardError, "Falha ao baixar áudio da URL: #{err}" unless status.success?

    Dir.glob(File.join(dir, "yt_audio.*")).first || raise(StandardError, "Áudio baixado não encontrado")
  end

  def executable_available?(bin)
    File.executable?(bin) || system("which", bin, out: File::NULL, err: File::NULL)
  end
end
