require "test_helper"

class AudiverisTranscriptionServiceTest < ActiveSupport::TestCase
  def sample_musicxml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <score-partwise version="3.1">
        <work><work-title>Audiveris Test</work-title></work>
        <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        <part id="P1">
          <measure number="1">
            <attributes><divisions>4</divisions></attributes>
            <note><pitch><step>C</step><octave>4</octave></pitch><duration>16</duration></note>
          </measure>
        </part>
      </score-partwise>
    XML
  end

  def with_fake_audiveris(script_body)
    Dir.mktmpdir("fake_audiveris_test") do |bin_dir|
      bin_path = File.join(bin_dir, "audiveris")
      File.write(bin_path, "#!/usr/bin/env bash\n#{script_body}\n")
      File.chmod(0o755, bin_path)
      yield bin_path
    end
  end

  test "executes audiveris -batch -transcribe -export -output preserving .pdf extension" do
    script = <<~SH
      args_file="$(dirname "$0")/captured_args.txt"
      printf '%s\n' "$@" > "$args_file"
      out_dir=""
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-output" ]]; then
          out_dir="$2"
          shift 2
        else
          shift
        fi
      done
      cat << 'EOF' > "$out_dir/result.musicxml"
      #{sample_musicxml}
      EOF
    SH

    with_fake_audiveris(script) do |bin_path|
      result = AudiverisTranscriptionService.call(
        input_bytes: "%PDF-1.4 fake",
        filename: "todo_no.pdf",
        bin: bin_path
      )

      assert_equal "result.musicxml", result.filename
      assert_includes result.content, "<work-title>Audiveris Test</work-title>"

      args = File.readlines(File.join(File.dirname(bin_path), "captured_args.txt"), chomp: true)
      assert_equal "-batch", args[0]
      assert_equal "-transcribe", args[1]
      assert_equal "-export", args[2]
      assert_equal "-swap", args[3]
      assert_includes args, "org.audiveris.omr.text.Language.defaultSpecification=eng"
      assert_includes args, "org.audiveris.omr.sheet.ProcessingSwitches.fingerings=true"
      assert_includes args, "org.audiveris.omr.sheet.ProcessingSwitches.chordNames=true"
      assert_includes args, "org.audiveris.omr.sheet.ProcessingSwitches.lyrics=true"
      assert_includes args, "org.audiveris.omr.sheet.ProcessingSwitches.disconnectedBracedParts=true"

      out_idx = args.index("-output")
      assert_not_nil out_idx
      assert_equal "--", args[out_idx + 2]
      assert File.basename(args[out_idx + 3]).end_with?(".pdf")
    end
  end

  test "passes custom ocr_language and validated -sheets arguments to Audiveris CLI" do
    script = <<~SH
      args_file="$(dirname "$0")/captured_args.txt"
      printf '%s\n' "$@" > "$args_file"
      out_dir=""
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-output" ]]; then
          out_dir="$2"
          shift 2
        else
          shift
        fi
      done
      cat << 'EOF' > "$out_dir/result.musicxml"
      #{sample_musicxml}
      EOF
    SH

    with_fake_audiveris(script) do |bin_path|
      AudiverisTranscriptionService.call(
        input_bytes: "%PDF-1.4 fake",
        filename: "songbook.pdf",
        bin: bin_path,
        ocr_language: "por",
        sheets: "1 3-5"
      )

      args = File.readlines(File.join(File.dirname(bin_path), "captured_args.txt"), chomp: true)
      assert_includes args, "org.audiveris.omr.text.Language.defaultSpecification=por"
      sheets_idx = args.index("-sheets")
      assert_not_nil sheets_idx
      assert_equal "1", args[sheets_idx + 1]
      assert_equal "3-5", args[sheets_idx + 2]
    end
  end

  test "raises Error for invalid sheets or ocr_language values" do
    err_sheets = assert_raises(AudiverisTranscriptionService::Error) do
      AudiverisTranscriptionService.call(input_bytes: "%PDF-1.4", filename: "a.pdf", bin: "/bin/true", sheets: "1-4; rm -rf /")
    end
    assert_match(/sheets/i, err_sheets.message)

    err_lang = assert_raises(AudiverisTranscriptionService::Error) do
      AudiverisTranscriptionService.call(input_bytes: "%PDF-1.4", filename: "a.pdf", bin: "/bin/true", ocr_language: "eng;id")
    end
    assert_match(/ocr/i, err_lang.message)
  end

  test "executes audiveris preserving .png extension for sheet music images" do
    script = <<~SH
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
      [[ "$input_file" == *.png ]] || { echo "Expected .png input" >&2; exit 1; }
      cat << 'EOF' > "$out_dir/image_score.musicxml"
      #{sample_musicxml}
      EOF
    SH

    with_fake_audiveris(script) do |bin_path|
      result = AudiverisTranscriptionService.call(
        input_bytes: "PNG_BYTES",
        filename: "page_1.png",
        bin: bin_path
      )

      assert_equal "image_score.musicxml", result.filename
    end
  end

  test "raises Error for unsupported file extension" do
    err = assert_raises(AudiverisTranscriptionService::Error) do
      AudiverisTranscriptionService.call(input_bytes: "hello", filename: "notes.txt", bin: "/bin/true")
    end
    assert_match(/unsupported/i, err.message)
  end

  test "raises Error when CLI binary is missing or not executable" do
    err = assert_raises(AudiverisTranscriptionService::Error) do
      AudiverisTranscriptionService.call(
        input_bytes: "%PDF-1.4",
        filename: "score.pdf",
        bin: "/nonexistent/audiveris_missing_bin"
      )
    end
    assert_match(/audiveris/i, err.message)
  end

  test "raises Error including stderr when CLI exits non-zero" do
    script = <<~SH
      echo "Corrupted PDF stream" >&2
      exit 2
    SH

    with_fake_audiveris(script) do |bin_path|
      err = assert_raises(AudiverisTranscriptionService::Error) do
        AudiverisTranscriptionService.call(input_bytes: "%PDF-1.4", filename: "bad.pdf", bin: bin_path)
      end
      assert_includes err.message, "Corrupted PDF stream"
    end
  end

  test "raises Error when CLI succeeds without generating MusicXML or MXL" do
    with_fake_audiveris("exit 0") do |bin_path|
      err = assert_raises(AudiverisTranscriptionService::Error) do
        AudiverisTranscriptionService.call(input_bytes: "%PDF-1.4", filename: "empty.pdf", bin: bin_path)
      end
      assert_match(/musicxml|mxl/i, err.message)
    end
  end

  test "raises Error on execution timeout" do
    with_fake_audiveris("sleep 1") do |bin_path|
      err = assert_raises(AudiverisTranscriptionService::Error) do
        AudiverisTranscriptionService.call(
          input_bytes: "%PDF-1.4",
          filename: "slow.pdf",
          bin: bin_path,
          timeout: 0.1
        )
      end
      assert_match(/timed out/i, err.message)
    end
  end
end
