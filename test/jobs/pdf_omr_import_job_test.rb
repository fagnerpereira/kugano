require "test_helper"

class PdfOmrImportJobTest < ActiveJob::TestCase
  def sample_xml(title = "PDF OMR Score")
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <score-partwise version="3.1">
        <work><work-title>#{title}</work-title></work>
        <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        <part id="P1">
          <measure number="1">
            <attributes><divisions>4</divisions></attributes>
            <note><pitch><step>D</step><octave>4</octave></pitch><duration>16</duration><staff>1</staff></note>
            <backup><duration>16</duration></backup>
            <note><pitch><step>D</step><octave>2</octave></pitch><duration>16</duration><staff>2</staff></note>
          </measure>
        </part>
      </score-partwise>
    XML
  end

  test "converts attached PDF via OMR CLI with -transcribe flag and imports MusicXML using MusicImporterService" do
    song = Song.create!(
      slug: "pdf-omr-score",
      title: "PDF OMR Score",
      source_type: "pdf_omr",
      status: "processing",
      payload: {}
    )
    song.source_file.attach(io: StringIO.new("%PDF-1.4 fake"), filename: "score.pdf", content_type: "application/pdf")

    Dir.mktmpdir("fake_omr_bin") do |bin_dir|
      fake_audiveris = File.join(bin_dir, "fake_audiveris")
      File.write(fake_audiveris, <<~SH)
        #!/usr/bin/env bash
        has_transcribe=0
        out_dir=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -transcribe)
              has_transcribe=1
              shift
              ;;
            -output)
              out_dir="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        if [[ "$has_transcribe" -ne 1 ]]; then
          echo "Missing -transcribe flag" >&2
          exit 1
        fi
        cat << 'EOF' > "$out_dir/score.musicxml"
        #{sample_xml("PDF OMR Score")}
        EOF
      SH
      File.chmod(0o755, fake_audiveris)

      prev_env = ENV["AUDIVERIS_BIN"]
      ENV["AUDIVERIS_BIN"] = fake_audiveris
      begin
        PdfOmrImportJob.perform_now(song.id)
      ensure
        ENV["AUDIVERIS_BIN"] = prev_env
      end
    end

    song.reload
    assert_equal "ready", song.status
    assert_equal "pdf_omr", song.payload.dig("meta", "sourceType")
    assert Songs::SchemaValidator.validate(song.payload).valid?
    assert_equal [ "D4" ], song.payload.dig("steps", 0, "levels", "original", "rh", 0, "notes")
  end

  test "converts attached PNG sheet music image preserving .png extension for Audiveris" do
    song = Song.create!(
      slug: "png-omr-score",
      title: "PNG OMR Score",
      source_type: "pdf_omr",
      status: "processing",
      payload: {}
    )
    song.source_file.attach(io: StringIO.new("FAKE_PNG"), filename: "sheet_page.png", content_type: "image/png")

    Dir.mktmpdir("fake_omr_png_bin") do |bin_dir|
      fake_audiveris = File.join(bin_dir, "fake_audiveris")
      File.write(fake_audiveris, <<~SH)
        #!/usr/bin/env bash
        out_dir=""
        input_file=""
        while [[ $# -gt 0 ]]; do
          if [[ "$1" == "-output" ]]; then
            out_dir="$2"
            shift 2
          else
            input_file="$1"
            shift
          fi
        done
        [[ "$input_file" == *.png ]] || { echo "Expected .png input, got $input_file" >&2; exit 1; }
        cat << 'EOF' > "$out_dir/sheet.musicxml"
        #{sample_xml("PNG OMR Score")}
        EOF
      SH
      File.chmod(0o755, fake_audiveris)

      prev_env = ENV["AUDIVERIS_BIN"]
      ENV["AUDIVERIS_BIN"] = fake_audiveris
      begin
        PdfOmrImportJob.perform_now(song.id)
      ensure
        ENV["AUDIVERIS_BIN"] = prev_env
      end
    end

    song.reload
    assert_equal "ready", song.status
    assert_equal "pdf_omr", song.payload.dig("meta", "sourceType")
    assert Songs::SchemaValidator.validate(song.payload).valid?
  end

  test "uses dedicated omr queue and forwards ocr_language and sheets options" do
    assert_equal "omr", PdfOmrImportJob.queue_name
    assert_equal "omr", AudioTranscriptionImportJob.queue_name

    song = Song.create!(
      slug: "songbook-slice",
      title: "Songbook Slice",
      source_type: "pdf_omr",
      status: "processing",
      payload: {}
    )
    song.source_file.attach(io: StringIO.new("%PDF-1.4"), filename: "book.pdf", content_type: "application/pdf")

    Dir.mktmpdir("fake_omr_opts") do |bin_dir|
      fake_audiveris = File.join(bin_dir, "fake_audiveris")
      File.write(fake_audiveris, <<~SH)
        #!/usr/bin/env bash
        printf '%s\n' "$@" > "#{bin_dir}/args.txt"
        out_dir=""
        while [[ $# -gt 0 ]]; do
          if [[ "$1" == "-output" ]]; then
            out_dir="$2"
            shift 2
          else
            shift
          fi
        done
        cat << 'EOF' > "$out_dir/book.musicxml"
        #{sample_xml("Songbook Slice")}
        EOF
      SH
      File.chmod(0o755, fake_audiveris)

      prev_env = ENV["AUDIVERIS_BIN"]
      ENV["AUDIVERIS_BIN"] = fake_audiveris
      begin
        PdfOmrImportJob.perform_now(song.id, ocr_language: "por", sheets: "1-2")
      ensure
        ENV["AUDIVERIS_BIN"] = prev_env
      end

      args = File.readlines(File.join(bin_dir, "args.txt"), chomp: true)
      assert_includes args, "org.audiveris.omr.text.Language.defaultSpecification=por"
      assert_includes args, "-sheets"
      assert_includes args, "1-2"
    end

    assert_equal "ready", song.reload.status
  end
end
