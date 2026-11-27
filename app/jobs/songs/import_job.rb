module Songs
  class ImportJob < ApplicationJob
    queue_as :default

    def perform(song_id)
      song = Song.find_by(id: song_id)
      return unless song

      bytes = song.source_file.attached? ? song.source_file.download : nil

      payload = case song.source_type
      when "musicxml"
        raise ArgumentError, "Arquivo MusicXML não anexado" if bytes.blank?
        Songs::Parsers::MusicXmlParser.parse(bytes, slug: song.slug, title: song.title, artist: song.artist)
      when "midi"
        raise ArgumentError, "Arquivo MIDI não anexado" if bytes.blank?
        Songs::Parsers::MidiParser.parse(bytes, slug: song.slug, title: song.title, artist: song.artist)
      when "pdf_omr"
        raise ArgumentError, "Arquivo PDF não anexado" if bytes.blank?
        Songs::Pipelines::PdfOmrPipeline.process(bytes, slug: song.slug, title: song.title, artist: song.artist)
      when "audio_youtube"
        Songs::Pipelines::AudioTranscriptionPipeline.process(
          audio_bytes: bytes,
          source_url: song.source_url,
          slug: song.slug,
          title: song.title,
          artist: song.artist
        )
      else
        raise ArgumentError, "Tipo de fonte não suportado para importação: #{song.source_type}"
      end

      song.update!(
        status: "ready",
        error_message: nil,
        payload: payload
      )
    rescue StandardError => e
      song&.update(
        status: "failed",
        error_message: e.message
      )
    end
  end
end
