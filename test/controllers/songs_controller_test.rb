require "test_helper"

class SongsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Songs::NativeCatalog.seed_all!
  end

  test "GET / studio root renders Todo No and the studio interface" do
    get root_url
    assert_response :success
    assert_select "#song-select option[value='todo-no']", text: /Todo Nó — Dingo Bells/
    assert_select "#level-select option[value='faithful']"
    assert_select "#sheet-svg"
    assert_select "#piano-bed"
    assert_select "#voice-bed"
    assert_select "#btn-focus"
    assert_select "#btn-theme"
    assert_select "#btn-sheet-zoom"
    assert_select "#chk-notes-on-sheet"
    assert_select ".hand-btn[data-hand='both']"
    assert_select ".hand-btn[data-hand='lh']"
    assert_select ".hand-btn[data-hand='rh']"
  end

  test "GET /songs/:id.json returns the canonical SongSchema payload" do
    get song_url("todo-no", format: :json)
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal "1.0", json["schemaVersion"]
    assert_equal "todo-no", json["slug"]
    assert_equal 80, json["steps"].size
    assert_equal 12, json["sections"].size
  end

  test "POST /songs enqueues Songs::ImportJob on Solid Queue / ActiveJob" do
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <score-partwise version="3.1">
        <work><work-title>Import Test</work-title></work>
        <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        <part id="P1">
          <measure number="1">
            <attributes><divisions>4</divisions></attributes>
            <note><pitch><step>E</step><octave>4</octave></pitch><duration>16</duration></note>
          </measure>
        </part>
      </score-partwise>
    XML

    file = Rack::Test::UploadedFile.new(StringIO.new(xml), "application/xml", false, original_filename: "meu_estudo.musicxml")

    assert_enqueued_with(job: Songs::ImportJob) do
      post songs_url(format: :json), params: { song: { title: "Meu Estudo", source_file: file } }
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "processing", body["status"]
    assert_equal "musicxml", body["source_type"]
  end

  test "POST /songs/import processes .musicxml and .mid synchronously into ready status" do
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <score-partwise version="3.1">
        <work><work-title>Direct XML</work-title></work>
        <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        <part id="P1">
          <measure number="1">
            <attributes><divisions>4</divisions></attributes>
            <note><pitch><step>G</step><octave>4</octave></pitch><duration>16</duration></note>
          </measure>
        </part>
      </score-partwise>
    XML

    file = Rack::Test::UploadedFile.new(StringIO.new(xml), "application/xml", false, original_filename: "direct.musicxml")

    assert_no_enqueued_jobs do
      post import_songs_url(format: :json), params: { song: { title: "Direct XML", source_file: file } }
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "ready", body["status"]
    assert_equal "musicxml", body["source_type"]
    assert_equal 1, body["total_measures"]
    assert_not_nil body.dig("payload", "steps")
  end

  test "POST /songs/import enqueues PdfOmrImportJob for .pdf files" do
    pdf_file = Rack::Test::UploadedFile.new(StringIO.new("%PDF-1.4"), "application/pdf", false, original_filename: "partitura.pdf")

    assert_enqueued_with(job: PdfOmrImportJob) do
      post import_songs_url(format: :json), params: { song: { title: "Partitura PDF", source_file: pdf_file } }
    end

    assert_response :accepted
    body = JSON.parse(response.body)
    assert_equal "processing", body["status"]
    assert_equal "pdf_omr", body["source_type"]
  end

  test "POST /songs/import enqueues AudioTranscriptionImportJob for audio files or YouTube URLs" do
    assert_enqueued_with(job: AudioTranscriptionImportJob) do
      post import_songs_url(format: :json), params: { song: { title: "YouTube Piano", source_url: "https://youtube.com/watch?v=dQw4w9WgXcQ" } }
    end

    assert_response :accepted
    body = JSON.parse(response.body)
    assert_equal "processing", body["status"]
    assert_equal "audio_youtube", body["source_type"]
  end

  test "POST /songs/import enqueues PdfOmrImportJob for sheet music images (.png)" do
    png_file = Rack::Test::UploadedFile.new(StringIO.new("FAKE_PNG"), "image/png", false, original_filename: "partitura.png")

    assert_enqueued_with(job: PdfOmrImportJob) do
      post import_songs_url(format: :json), params: { song: { title: "Partitura PNG", source_file: png_file } }
    end

    assert_response :accepted
    body = JSON.parse(response.body)
    assert_equal "processing", body["status"]
    assert_equal "pdf_omr", body["source_type"]
  end

  test "POST /songs/import rejects empty submission without file or URL" do
    assert_no_difference("Song.count") do
      assert_no_enqueued_jobs do
        post import_songs_url(format: :json), params: { song: { title: "" } }
      end
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert body["error"].present?
  end

  test "GET /?importing=<slug> opens import drawer and displays processing or failed status" do
    song = Song.create!(
      slug: "processing-pdf",
      title: "Meu PDF",
      source_type: "pdf_omr",
      status: "processing",
      payload: {}
    )

    get root_url(importing: "processing-pdf")
    assert_response :success
    assert_select "#app-shell[data-piano-studio-importing-song-value='processing-pdf']"
    assert_select "#import-drawer:not(.hidden)"
    assert_select "#import-status-badge", /Transcrevendo.*Meu PDF/

    song.update!(status: "failed", error_message: "PDF corrompido")
    get root_url(importing: "processing-pdf")
    assert_response :success
    assert_select "#import-drawer:not(.hidden)"
    assert_select "#import-status-badge", /PDF corrompido/
  end

  test "GET / layout only links compiled application stylesheet and not raw tailwind source" do
    get root_url
    assert_response :success
    assert_not_includes response.body, "application.tailwind"
  end

  test "POST /songs/import forwards ocr_language and sheets options to PdfOmrImportJob on omr queue" do
    pdf_file = Rack::Test::UploadedFile.new(StringIO.new("%PDF-1.4"), "application/pdf", false, original_filename: "songbook.pdf")

    enqueued = assert_enqueued_with(job: PdfOmrImportJob, queue: "omr") do
      post import_songs_url(format: :json), params: {
        song: {
          title: "Songbook",
          source_file: pdf_file,
          ocr_language: "por",
          sheets: "1-4"
        }
      }
    end

    assert_response :accepted
    assert_equal({ ocr_language: "por", sheets: "1-4" }, enqueued.arguments.last)
  end
end
