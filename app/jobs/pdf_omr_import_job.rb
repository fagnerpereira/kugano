# Background ActiveJob (executed by Solid Queue on the dedicated +:omr+ queue) that
# converts an uploaded PDF or sheet music image via {AudiverisTranscriptionService}
# and deterministically imports the resulting MusicXML/MXL into the SongSchema payload.
class PdfOmrImportJob < ApplicationJob
  queue_as :omr

  # Processes the uploaded OMR attachment for +song_id+ and transitions the
  # {Song} record to +ready+ or +failed+.
  #
  # ==== Options
  # * +ocr_language+ - Optional Tesseract OCR language code (+eng+, +por+, +eng+por+).
  # * +sheets+ - Optional page/sheet selection string forwarded to +-sheets+.
  def perform(song_id, ocr_language: nil, sheets: nil)
    song = Song.find_by(id: song_id)
    return unless song
    raise ArgumentError, "Arquivo PDF ou imagem não anexado" unless song.source_file.attached?

    omr_result = AudiverisTranscriptionService.call(
      input_bytes: song.source_file.download,
      filename: song.source_file.filename.to_s,
      ocr_language: ocr_language,
      sheets: sheets
    )

    payload = MusicImporterService.call(
      content: omr_result.content,
      filename: omr_result.filename,
      slug: song.slug,
      title: song.title,
      artist: song.artist
    )
    payload["meta"]["sourceType"] = "pdf_omr"

    song.update!(status: "ready", error_message: nil, payload: payload)
  rescue StandardError => e
    song&.update(status: "failed", error_message: e.message)
  end
end
