require "open3"
require "timeout"

# = Overview
#
# Executes the Audiveris Optical Music Recognition (OMR) batch CLI to convert
# sheet music PDFs and images into deterministic MusicXML / MXL files.
#
# Following the Audiveris Handbook recommendations, each batch invocation:
# * Enables +-swap+ to offload processed sheets to disk and bound JVM memory.
# * Sets +Language.defaultSpecification+ so Tesseract OCR runs cleanly.
# * Activates piano-relevant +ProcessingSwitches+ (+fingerings+, +chordNames+,
#   +lyrics+, and +disconnectedBracedParts+).
# * Supports optional +-sheets+ page selection and uses +-- + before the input path.
class AudiverisTranscriptionService
  # File extensions accepted by the Audiveris batch CLI.
  SUPPORTED_EXTENSIONS = %w[.pdf .png .jpg .jpeg .tif .tiff].freeze

  # Supported Tesseract OCR language specifications (Handbook pp. 73-76).
  ALLOWED_OCR_LANGUAGES = %w[eng por eng+por por+eng].freeze

  # Default OCR language specification when none is requested.
  DEFAULT_OCR_LANGUAGE = "eng".freeze

  # Validation pattern for Audiveris +-sheets+ ranges (e.g. "1 3-5").
  SHEETS_REGEX = /\A\d+(?:-\d+)?(?:\s+\d+(?:-\d+)?)*\z/

  # Piano-oriented Audiveris switches disabled or conditional by default (Handbook pp. 82, 343).
  PIANO_PROCESSING_SWITCHES = %w[
    fingerings
    chordNames
    lyrics
    disconnectedBracedParts
  ].freeze

  # Default maximum execution time (in seconds) for an Audiveris CLI run.
  DEFAULT_TIMEOUT_SECONDS = 180

  # Raised when validation, CLI availability, timeout, or OMR export fails.
  class Error < StandardError; end

  # Immutable result returned after a successful OMR transcription.
  Result = Struct.new(:filename, :content, :stdout, :stderr, keyword_init: true)

  # Transcribes +input_bytes+ (with original +filename+) into MusicXML or MXL.
  #
  # ==== Options
  # * +input_bytes+ - Raw binary contents of the uploaded PDF or image.
  # * +filename+ - Original filename used to preserve the input extension.
  # * +bin+ - Optional override for the Audiveris executable path.
  # * +timeout+ - Optional timeout in seconds (defaults to +DEFAULT_TIMEOUT_SECONDS+).
  # * +ocr_language+ - Optional OCR language code (+eng+, +por+, +eng+por+, +por+eng+).
  # * +sheets+ - Optional sheet numbers/ranges for +-sheets+ (e.g. +"1 3-5"+).
  def self.call(input_bytes:, filename:, bin: nil, timeout: nil, ocr_language: nil, sheets: nil)
    new(
      input_bytes: input_bytes,
      filename: filename,
      bin: bin,
      timeout: timeout,
      ocr_language: ocr_language,
      sheets: sheets
    ).call
  end

  # Initializes a transcription request for a single sheet music file.
  def initialize(input_bytes:, filename:, bin: nil, timeout: nil, ocr_language: nil, sheets: nil)
    @input_bytes = input_bytes
    @filename = filename.to_s
    @bin = bin
    @timeout = (timeout || DEFAULT_TIMEOUT_SECONDS).to_f
    @ocr_language = ocr_language.presence || ENV.fetch("AUDIVERIS_OCR_LANGUAGE", DEFAULT_OCR_LANGUAGE)
    @sheets = sheets.to_s.strip
  end

  # Runs the Audiveris CLI in batch mode and returns a {Result} containing the
  # exported +.mxl+ / +.musicxml+ / +.xml+ payload.
  def call
    ext = validate_input!
    @ocr_language = validate_ocr_language!
    @sheet_tokens = validate_sheets!
    audiveris_bin = resolve_executable!

    Dir.mktmpdir("audiveris_omr") do |dir|
      input_path = File.join(dir, "input#{ext}")
      File.binwrite(input_path, @input_bytes)

      stdout, stderr, status = run_with_timeout(audiveris_bin, dir, input_path)
      unless status.success?
        detail = stderr.to_s.strip.presence || stdout.to_s.strip.presence || "no output"
        raise Error, "Audiveris OMR conversion failed (exit #{status.exitstatus}): #{detail}"
      end

      exported_file = locate_exported_score(dir)
      raise Error, "Audiveris OMR did not generate a .mxl or .musicxml file" unless exported_file

      Result.new(
        filename: File.basename(exported_file),
        content: File.binread(exported_file),
        stdout: stdout,
        stderr: stderr
      )
    end
  end

  private

  def validate_input!
    raise Error, "Sheet music input bytes cannot be blank" if @input_bytes.blank?

    ext = File.extname(@filename).downcase
    unless SUPPORTED_EXTENSIONS.include?(ext)
      raise Error, "Unsupported OMR file extension '#{ext}'. Allowed: #{SUPPORTED_EXTENSIONS.join(', ')}"
    end

    ext
  end

  def validate_ocr_language!
    lang = @ocr_language.to_s.strip
    unless ALLOWED_OCR_LANGUAGES.include?(lang)
      raise Error, "Unsupported OCR language '#{lang}'. Allowed: #{ALLOWED_OCR_LANGUAGES.join(', ')}"
    end

    lang
  end

  def validate_sheets!
    return [] if @sheets.empty?

    unless @sheets.match?(SHEETS_REGEX)
      raise Error, "Invalid -sheets specification '#{@sheets}'. Expected numbers or ranges like '1 3-5'."
    end

    @sheets.split
  end

  def resolve_executable!
    audiveris_bin = @bin.presence || ENV.fetch("AUDIVERIS_BIN", "audiveris")
    available = File.executable?(audiveris_bin) || system("which", audiveris_bin, out: File::NULL, err: File::NULL)
    unless available
      raise Error, "Audiveris OMR CLI executable not found (#{audiveris_bin})."
    end

    audiveris_bin
  end

  def build_command(audiveris_bin, output_dir, input_path)
    cmd = [
      audiveris_bin,
      "-batch",
      "-transcribe",
      "-export",
      "-swap",
      "-constant", "org.audiveris.omr.text.Language.defaultSpecification=#{@ocr_language}"
    ]

    PIANO_PROCESSING_SWITCHES.each do |switch|
      cmd.push("-constant", "org.audiveris.omr.sheet.ProcessingSwitches.#{switch}=true")
    end

    cmd.push("-sheets", *@sheet_tokens) if @sheet_tokens.any?
    cmd.push("-output", output_dir, "--", input_path)
    cmd
  end

  def locate_exported_score(output_dir)
    Dir.glob(File.join(output_dir, "**", "*.{mxl,musicxml}")).sort.first ||
      Dir.glob(File.join(output_dir, "**", "*.xml")).sort.first
  end

  def run_with_timeout(audiveris_bin, output_dir, input_path)
    cmd = build_command(audiveris_bin, output_dir, input_path)
    Timeout.timeout(@timeout) do
      Open3.capture3(*cmd)
    end
  rescue Timeout::Error
    raise Error, "Audiveris OMR execution timed out after #{@timeout}s"
  end
end
