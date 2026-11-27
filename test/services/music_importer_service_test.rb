require "test_helper"

class MusicImporterServiceTest < ActiveSupport::TestCase
  def sample_musicxml_with_voice
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <score-partwise version="3.1">
        <work><work-title>Canção com Voz</work-title></work>
        <identification><creator type="composer">Compositor Teste</creator></identification>
        <part-list>
          <score-part id="P1"><part-name>Voice</part-name></score-part>
          <score-part id="P2"><part-name>Piano</part-name></score-part>
        </part-list>
        <part id="P1">
          <measure number="1">
            <attributes>
              <divisions>4</divisions>
              <key><fifths>2</fifths><mode>major</mode></key>
              <time><beats>4</beats><beat-type>4</beat-type></time>
            </attributes>
            <note>
              <pitch><step>F</step><alter>1</alter><octave>4</octave></pitch>
              <duration>8</duration>
              <lyric><text>Tan-to</text></lyric>
            </note>
            <note>
              <pitch><step>A</step><octave>4</octave></pitch>
              <duration>8</duration>
              <lyric><text>faz</text></lyric>
            </note>
          </measure>
        </part>
        <part id="P2">
          <measure number="1">
            <attributes>
              <divisions>4</divisions>
              <key><fifths>2</fifths><mode>major</mode></key>
              <time><beats>4</beats><beat-type>4</beat-type></time>
              <staves>2</staves>
            </attributes>
            <direction><sound tempo="76"/></direction>
            <harmony><root><root-step>D</root-step></root><kind>major</kind></harmony>
            <note>
              <pitch><step>D</step><octave>4</octave></pitch>
              <duration>8</duration>
              <staff>1</staff>
            </note>
            <note>
              <chord/>
              <pitch><step>F</step><alter>1</alter><octave>4</octave></pitch>
              <duration>8</duration>
              <staff>1</staff>
            </note>
            <note>
              <chord/>
              <pitch><step>A</step><octave>4</octave></pitch>
              <duration>8</duration>
              <staff>1</staff>
            </note>
            <note>
              <pitch><step>B</step><octave>4</octave></pitch>
              <duration>8</duration>
              <staff>1</staff>
            </note>
            <backup><duration>16</duration></backup>
            <note>
              <pitch><step>D</step><octave>2</octave></pitch>
              <duration>16</duration>
              <staff>2</staff>
            </note>
          </measure>
        </part>
      </score-partwise>
    XML
  end

  def sample_midi_bytes
    track_events = +""
    track_events << "\x00\xFF\x51\x03\x07\xA1\x20".b # 120 BPM
    track_events << "\x00\x90\x30\x5A".b # C3 (LH)
    track_events << "\x00\x90\x3C\x5A".b # C4 (RH)
    track_events << "\x00\x90\x40\x5A".b # E4 (RH)
    track_events << "\x00\x90\x43\x5A".b # G4 (RH)
    track_events << "\x81\x40\x80\x3C\x00".b
    track_events << "\x00\x80\x40\x00".b
    track_events << "\x00\x80\x43\x00".b
    track_events << "\x00\x90\x45\x5A".b # A4 (RH)
    track_events << "\x81\x40\x80\x45\x00".b
    track_events << "\x00\x80\x30\x00".b
    track_events << "\x00\xFF\x2F\x00".b

    header = "MThd".b + [ 6, 0, 1, 96 ].pack("Nn3")
    track = "MTrk".b + [ track_events.bytesize ].pack("N") + track_events
    header + track
  end

  test "imports .musicxml / .xml deterministically separating RH, LH, and Voice into SongSchema" do
    payload = MusicImporterService.call(
      content: sample_musicxml_with_voice,
      filename: "cancao.musicxml",
      slug: "cancao-com-voz"
    )

    validation = Songs::SchemaValidator.validate(payload)
    assert validation.valid?, "Expected valid SongSchema, got: #{validation.errors.join(', ')}"

    step = payload["steps"].first
    assert_equal [ "F#4", "A4" ], step["voice"].map { |v| v["note"] }
    assert_includes step["lyric"], "Tan-to"
    assert_equal [ "D2" ], step.dig("levels", "original", "lh", 0, "notes")
    assert_equal [ "D4", "F#4", "A4" ], step.dig("levels", "original", "rh", 0, "notes")
  end

  test "imports compressed .mxl deterministically into SongSchema" do
    Dir.mktmpdir("mxl_test") do |dir|
      xml_path = File.join(dir, "score.xml")
      mxl_path = File.join(dir, "score.mxl")
      File.write(xml_path, sample_musicxml_with_voice)
      system("zip", "-q", "-j", mxl_path, xml_path)

      payload = MusicImporterService.call(
        content: File.binread(mxl_path),
        filename: "score.mxl",
        slug: "score-mxl"
      )

      assert Songs::SchemaValidator.validate(payload).valid?
      assert_equal "Canção com Voz", payload.dig("meta", "title")
    end
  end

  test "imports .mid deterministically separating LH and RH into SongSchema" do
    payload = MusicImporterService.call(
      content: sample_midi_bytes,
      filename: "estudo.mid",
      slug: "estudo-mid"
    )

    assert Songs::SchemaValidator.validate(payload).valid?
    step = payload["steps"].first
    assert_equal [ "C3" ], step.dig("levels", "original", "lh", 0, "notes")
    assert_equal [ "C4", "E4", "G4" ], step.dig("levels", "original", "rh", 0, "notes")
  end

  test "supports 3/4 time, movement-title, metronome tempo, harmony bass/kind text, and tied notes" do
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <score-partwise version="3.1">
        <movement-title>Valsa em 3/4</movement-title>
        <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        <part id="P1">
          <measure number="1">
            <attributes>
              <divisions>4</divisions>
              <key><fifths>0</fifths><mode>major</mode></key>
              <time><beats>3</beats><beat-type>4</beat-type></time>
              <staves>2</staves>
            </attributes>
            <direction>
              <direction-type>
                <metronome><beat-unit>quarter</beat-unit><per-minute>92</per-minute></metronome>
              </direction-type>
            </direction>
            <harmony>
              <root><root-step>D</root-step></root>
              <kind text="m7">minor-seventh</kind>
              <bass><bass-step>F</bass-step><bass-alter>1</bass-alter></bass>
            </harmony>
            <note>
              <pitch><step>A</step><octave>4</octave></pitch>
              <duration>8</duration>
              <tie type="start"/>
              <staff>1</staff>
            </note>
            <note>
              <pitch><step>A</step><octave>4</octave></pitch>
              <duration>4</duration>
              <tie type="stop"/>
              <staff>1</staff>
            </note>
            <backup><duration>12</duration></backup>
            <note>
              <pitch><step>F</step><alter>1</alter><octave>2</octave></pitch>
              <duration>12</duration>
              <staff>2</staff>
            </note>
          </measure>
        </part>
      </score-partwise>
    XML

    payload = MusicImporterService.call(content: xml, filename: "valsa.musicxml", slug: "valsa-3-4")

    assert Songs::SchemaValidator.validate(payload).valid?
    assert_equal "Valsa em 3/4", payload.dig("meta", "title")
    assert_equal 92, payload.dig("meta", "defaultBpm")
    assert_equal "3/4", payload.dig("meta", "timeSignature")
    assert_equal 12, payload.dig("meta", "ticksPerMeasure")

    step = payload["steps"].first
    assert_equal "Dm7/F#", step.dig("levels", "original", "chord")
    # Tied stop note should not trigger a duplicate strike in RH
    assert_equal 1, step.dig("levels", "original", "rh").size
  end
end
