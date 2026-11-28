class SongsController < ApplicationController
  DIRECT_SOURCE_TYPES = %w[musicxml midi].freeze

  def index
    songs = Song.order(created_at: :desc)
    render json: songs.map { |s| serialize_summary(s) }
  end

  def show
    song = Song.find_by(slug: params[:id]) || Song.find_by(id: params[:id])
    if song.nil?
      render json: { error: "Música não encontrada" }, status: :not_found
    elsif song.ready?
      render json: song.payload
    else
      render json: serialize_summary(song)
    end
  end

  def create
    song, uploaded = build_song_from_params
    return render_missing_input_error if uploaded.blank? && song.source_url.blank?

    song.source_file.attach(uploaded) if uploaded.present?

    if song.save
      Songs::ImportJob.perform_later(song.id)
      respond_to do |format|
        format.json { render json: serialize_summary(song), status: :created }
        format.html { redirect_to root_path(importing: song.slug), notice: "Partitura enviada para processamento via Solid Queue." }
      end
    else
      render_song_errors(song)
    end
  end

  def import
    song, uploaded = build_song_from_params
    return render_missing_input_error if uploaded.blank? && song.source_url.blank?

    if DIRECT_SOURCE_TYPES.include?(song.source_type) && uploaded.present?
      raw_bytes = uploaded.read
      uploaded.rewind if uploaded.respond_to?(:rewind)
      payload = MusicImporterService.call(
        content: raw_bytes,
        filename: uploaded.original_filename.to_s,
        slug: song.slug,
        title: song.title,
        artist: song.artist
      )
      song.status = "ready"
      song.payload = payload
      song.source_file.attach(uploaded)

      if song.save
        respond_to do |format|
          format.json { render json: serialize_summary(song, include_payload: true), status: :created }
          format.html { redirect_to root_path(song: song.slug), notice: "Partitura importada com sucesso." }
        end
      else
        render_song_errors(song)
      end
    else
      song.source_file.attach(uploaded) if uploaded.present?
      if song.save
        enqueue_solid_queue_job(song)
        respond_to do |format|
          format.json { render json: serialize_summary(song), status: :accepted }
          format.html { redirect_to root_path(importing: song.slug), notice: "Arquivo enfileirado no Solid Queue." }
        end
      else
        render_song_errors(song)
      end
    end
  rescue ArgumentError => e
    respond_to do |format|
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
      format.html { redirect_to root_path, alert: e.message }
    end
  end

  private

  def song_params
    params.fetch(:song, {}).permit(:title, :artist, :source_file, :source_url, :ocr_language, :sheets)
  end

  def build_song_from_params
    uploaded = song_params[:source_file]
    source_url = song_params[:source_url].to_s.strip
    source_type = detect_source_type(uploaded, source_url)

    raw_title = song_params[:title].presence ||
                uploaded&.original_filename&.sub(/\.\w+\z/, "")&.tr("_-", " ")&.titleize ||
                "Partitura Importada"
    base_slug = raw_title.parameterize.presence || "song"
    slug = "#{base_slug}-#{SecureRandom.hex(3)}"

    song = Song.new(
      slug: slug,
      title: raw_title,
      artist: song_params[:artist].presence || "Importado",
      source_type: source_type,
      source_url: source_url.presence,
      status: "processing",
      payload: {}
    )
    [ song, uploaded ]
  end

  def enqueue_solid_queue_job(song)
    case song.source_type
    when "pdf_omr"
      PdfOmrImportJob.perform_later(song.id, **omr_job_options)
    when "audio_youtube"
      AudioTranscriptionImportJob.perform_later(song.id)
    else
      Songs::ImportJob.perform_later(song.id)
    end
  end

  def omr_job_options
    opts = {}
    opts[:ocr_language] = song_params[:ocr_language].to_s.strip if song_params[:ocr_language].present?
    opts[:sheets] = song_params[:sheets].to_s.strip if song_params[:sheets].present?
    opts
  end

  def render_missing_input_error
    message = "Envie um arquivo de partitura/MIDI/PDF/áudio ou informe uma URL."
    respond_to do |format|
      format.json { render json: { error: message }, status: :unprocessable_entity }
      format.html { redirect_to root_path, alert: message }
    end
  end

  def render_song_errors(song)
    respond_to do |format|
      format.json { render json: { errors: song.errors.full_messages }, status: :unprocessable_entity }
      format.html { redirect_to root_path, alert: song.errors.full_messages.join(", ") }
    end
  end

  def detect_source_type(uploaded, source_url)
    return "audio_youtube" if source_url.present?
    return "musicxml" unless uploaded.respond_to?(:original_filename)

    ext = File.extname(uploaded.original_filename.to_s).downcase
    case ext
    when ".musicxml", ".xml", ".mxl"
      "musicxml"
    when ".mid", ".midi"
      "midi"
    when ".pdf", ".png", ".jpg", ".jpeg", ".tif", ".tiff"
      "pdf_omr"
    when ".mp3", ".wav", ".ogg", ".flac", ".m4a", ".webm", ".opus", ".aac"
      "audio_youtube"
    else
      uploaded.respond_to?(:content_type) && uploaded.content_type.to_s.start_with?("audio/") ? "audio_youtube" : "musicxml"
    end
  end

  def serialize_summary(song, include_payload: false)
    summary = {
      id: song.id,
      slug: song.slug,
      title: song.title,
      artist: song.artist,
      source_type: song.source_type,
      status: song.status,
      error_message: song.error_message,
      key_signature: song.key_signature,
      default_bpm: song.default_bpm,
      time_signature: song.time_signature,
      total_measures: song.total_measures
    }
    summary[:payload] = song.payload if include_payload
    summary
  end
end
