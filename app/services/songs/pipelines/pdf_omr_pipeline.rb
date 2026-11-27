module Songs
  module Pipelines
    # Synchronous OMR pipeline wrapper that delegates Audiveris execution to
    # {AudiverisTranscriptionService} and feeds the resulting MusicXML/MXL into
    # {Songs::Parsers::MusicXmlParser}.
    class PdfOmrPipeline
      class OmrUnavailableError < StandardError; end

      # Processes raw +pdf_bytes+ and returns a validated SongSchema hash.
      def self.process(pdf_bytes, slug:, title: nil, artist: nil, filename: nil)
        new(pdf_bytes, slug: slug, title: title, artist: artist, filename: filename).process
      end

      def initialize(pdf_bytes, slug:, title: nil, artist: nil, filename: nil)
        @pdf_bytes = pdf_bytes
        @slug = slug
        @title = title
        @artist = artist
        @filename = filename.presence || "#{slug}.pdf"
      end

      # Executes Audiveris OMR and parses the exported MusicXML deterministically.
      def process
        omr_result = AudiverisTranscriptionService.call(
          input_bytes: @pdf_bytes,
          filename: @filename
        )

        Songs::Parsers::MusicXmlParser.parse(
          omr_result.content,
          slug: @slug,
          title: @title,
          artist: @artist,
          source_type: "pdf_omr"
        )
      rescue AudiverisTranscriptionService::Error => e
        raise OmrUnavailableError, e.message
      end
    end
  end
end
