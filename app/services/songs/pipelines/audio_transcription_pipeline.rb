require "open3"

module Songs
  module Pipelines
    class AudioTranscriptionPipeline
      class TranscriptionUnavailableError < StandardError; end

      def self.process(audio_bytes: nil, source_url: nil, slug:, title: nil, artist: nil)
        new(audio_bytes: audio_bytes, source_url: source_url, slug: slug, title: title, artist: artist).process
      end

      def initialize(audio_bytes: nil, source_url: nil, slug:, title: nil, artist: nil)
        @audio_bytes = audio_bytes
        @source_url = source_url
        @slug = slug
        @title = title
        @artist = artist
      end

      def process
        transcriber_bin = ENV.fetch("BASIC_PITCH_BIN", "basic-pitch")
        unless system("which", transcriber_bin, out: File::NULL, err: File::NULL)
          raise TranscriptionUnavailableError, "Pipeline de transcrição de áudio (basic-pitch) não instalado no ambiente."
        end

        Dir.mktmpdir("audio_transcribe") do |dir|
          audio_path = prepare_audio_input(dir)
          _out, err, status = Open3.capture3(transcriber_bin, dir, audio_path)
          raise TranscriptionUnavailableError, "Falha na transcrição para MIDI: #{err}" unless status.success?

          midi_file = Dir.glob(File.join(dir, "**", "*.{mid,midi}")).first
          raise TranscriptionUnavailableError, "Nenhum arquivo MIDI foi gerado pela transcrição" unless midi_file

          Songs::Parsers::MidiParser.parse(
            File.binread(midi_file),
            slug: @slug,
            title: @title,
            artist: @artist,
            source_type: "audio_youtube"
          )
        end
      end

      private

      def prepare_audio_input(dir)
        if @audio_bytes.present?
          path = File.join(dir, "input_audio.wav")
          File.binwrite(path, @audio_bytes)
          return path
        end

        raise TranscriptionUnavailableError, "Arquivo de áudio ou URL ausente" if @source_url.blank?

        yt_bin = ENV.fetch("YTDLP_BIN", "yt-dlp")
        unless system("which", yt_bin, out: File::NULL, err: File::NULL)
          raise TranscriptionUnavailableError, "yt-dlp não encontrado para baixar áudio da URL informada."
        end

        out_template = File.join(dir, "youtube_audio.%(ext)s")
        _out, err, status = Open3.capture3(yt_bin, "-x", "--audio-format", "wav", "-o", out_template, @source_url)
        raise TranscriptionUnavailableError, "Falha ao obter áudio: #{err}" unless status.success?

        Dir.glob(File.join(dir, "youtube_audio.*")).first || raise(TranscriptionUnavailableError, "Áudio baixado não encontrado")
      end
    end
  end
end
