require "test_helper"

module Songs
  module Parsers
    class MusicXmlParserTest < ActiveSupport::TestCase
      def sample_musicxml
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <score-partwise version="3.1">
            <work><work-title>Estudo em Ré</work-title></work>
            <identification><creator type="composer">Estúdio Piano</creator></identification>
            <part-list>
              <score-part id="P1"><part-name>Piano</part-name></score-part>
            </part-list>
            <part id="P1">
              <measure number="1">
                <attributes>
                  <divisions>4</divisions>
                  <key><fifths>2</fifths><mode>major</mode></key>
                  <time><beats>4</beats><beat-type>4</beat-type></time>
                  <staves>2</staves>
                  <clef number="1"><sign>G</sign><line>2</line></clef>
                  <clef number="2"><sign>F</sign><line>4</line></clef>
                </attributes>
                <direction>
                  <sound tempo="76"/>
                </direction>
                <harmony>
                  <root><root-step>D</root-step></root>
                  <kind>major</kind>
                </harmony>
                <!-- RH chord on beat 1 (duration 8 = 2 beats) -->
                <note>
                  <pitch><step>D</step><octave>4</octave></pitch>
                  <duration>8</duration>
                  <staff>1</staff>
                  <notations><technical><fingering>1</fingering></technical></notations>
                  <lyric><text>Tan-to</text></lyric>
                </note>
                <note>
                  <chord/>
                  <pitch><step>F</step><alter>1</alter><octave>4</octave></pitch>
                  <duration>8</duration>
                  <staff>1</staff>
                  <notations><technical><fingering>2</fingering></technical></notations>
                </note>
                <note>
                  <chord/>
                  <pitch><step>A</step><octave>4</octave></pitch>
                  <duration>8</duration>
                  <staff>1</staff>
                  <notations><technical><fingering>4</fingering></technical></notations>
                </note>
                <!-- RH note on beat 3 (duration 8 = 2 beats) -->
                <note>
                  <pitch><step>B</step><octave>4</octave></pitch>
                  <duration>8</duration>
                  <staff>1</staff>
                  <notations><technical><fingering>5</fingering></technical></notations>
                  <lyric><text>faz</text></lyric>
                </note>
                <backup><duration>16</duration></backup>
                <!-- LH bass note for whole measure (duration 16 = 4 beats) -->
                <note>
                  <pitch><step>D</step><octave>2</octave></pitch>
                  <duration>16</duration>
                  <staff>2</staff>
                  <notations><technical><fingering>5</fingering></technical></notations>
                </note>
              </measure>
            </part>
          </score-partwise>
        XML
      end

      test "deterministically parses MusicXML into valid SongSchema with 4 connected levels" do
        payload = Songs::Parsers::MusicXmlParser.parse(
          sample_musicxml,
          slug: "estudo-em-re",
          title: "Estudo em Ré"
        )

        validation = Songs::SchemaValidator.validate(payload)
        assert validation.valid?, "MusicXML payload failed validation: #{validation.errors.join(', ')}"

        assert_equal "estudo-em-re", payload["slug"]
        assert_equal "D", payload.dig("meta", "key")
        assert_equal 76, payload.dig("meta", "defaultBpm")
        assert_equal "musicxml", payload.dig("meta", "sourceType")
        assert_equal 1, payload["steps"].size

        step1 = payload["steps"].first
        assert_includes step1["lyric"], "Tan-to"
        assert_equal "D", step1.dig("levels", "original", "chord")

        orig_rh = step1.dig("levels", "original", "rh")
        assert_equal 2, orig_rh.size
        assert_equal 0, orig_rh[0]["tick"]
        assert_equal 8, orig_rh[0]["dur"]
        assert_equal [ "D4", "F#4", "A4" ], orig_rh[0]["notes"]
        assert_equal [ 1, 2, 4 ], orig_rh[0]["fingers"]

        assert_equal 8, orig_rh[1]["tick"]
        assert_equal [ "B4" ], orig_rh[1]["notes"]
        assert_equal [ 5 ], orig_rh[1]["fingers"]

        orig_lh = step1.dig("levels", "original", "lh")
        assert_equal [ "D2" ], orig_lh[0]["notes"]
        assert_equal [ 5 ], orig_lh[0]["fingers"]
      end
    end
  end
end
