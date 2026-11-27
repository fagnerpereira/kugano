require "test_helper"

module Songs
  class ImportJobTest < ActiveJob::TestCase
    def sample_xml
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="3.1">
          <work><work-title>Valsa Simples</work-title></work>
          <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>4</divisions>
                <key><fifths>0</fifths><mode>major</mode></key>
                <time><beats>4</beats><beat-type>4</beat-type></time>
              </attributes>
              <note>
                <pitch><step>C</step><octave>4</octave></pitch>
                <duration>16</duration>
                <staff>1</staff>
              </note>
              <backup><duration>16</duration></backup>
              <note>
                <pitch><step>C</step><octave>3</octave></pitch>
                <duration>16</duration>
                <staff>2</staff>
              </note>
            </measure>
          </part>
        </score-partwise>
      XML
    end

    test "processes an attached MusicXML file into ready state with valid SongSchema" do
      song = Song.create!(
        slug: "valsa-simples",
        title: "Valsa Simples",
        source_type: "musicxml",
        status: "processing",
        payload: {}
      )
      song.source_file.attach(
        io: StringIO.new(sample_xml),
        filename: "valsa.musicxml",
        content_type: "application/vnd.recordare.musicxml+xml"
      )

      Songs::ImportJob.perform_now(song.id)

      song.reload
      assert_equal "ready", song.status
      assert_equal 1, song.total_measures
      assert_equal "C", song.key_signature
      assert Songs::SchemaValidator.validate(song.payload).valid?
    end

    test "marks song as failed with diagnostic error when file is corrupted" do
      song = Song.create!(
        slug: "corrupted-midi",
        title: "Corrupted MIDI",
        source_type: "midi",
        status: "processing",
        payload: {}
      )
      song.source_file.attach(
        io: StringIO.new("NOT_A_MIDI_FILE"),
        filename: "broken.mid",
        content_type: "audio/midi"
      )

      Songs::ImportJob.perform_now(song.id)

      song.reload
      assert_equal "failed", song.status
      assert_includes song.error_message, "MThd"
    end
  end
end
