require "test_helper"

module Songs
  class NativeCatalogTest < ActiveSupport::TestCase
    test "exports Todo No with all 80 measures, 12 sections, and valid SongSchema" do
      todo_no = Songs::NativeCatalog.fetch("todo-no")
      assert_not_nil todo_no

      validation = Songs::SchemaValidator.validate(todo_no)
      assert validation.valid?, "Todo Nó failed SongSchema validation: #{validation.errors.join(', ')}"

      assert_equal "Todo Nó — Dingo Bells", todo_no.dig("meta", "title")
      assert_equal 76, todo_no.dig("meta", "defaultBpm")
      assert_equal 12, todo_no["sections"].size
      assert_equal 80, todo_no["steps"].size

      # Check Measure 1 (Intro D), Measure 5 (Verso 1 with voice), Measure 62 (Subida Cromática), Measure 80 (Final D)
      comp1 = todo_no["steps"][0]
      assert_equal "Comp. 1", comp1["tag"]
      assert_equal "D", comp1.dig("levels", "easy", "chord")
      assert_equal "D → Daug", comp1.dig("levels", "original", "chord")

      comp5 = todo_no["steps"][4]
      assert_equal 5, comp5["id"]
      assert_equal 2, comp5["sectionId"]
      assert_equal 4, comp5["voice"].size
      assert_equal "F#4", comp5["voice"][0]["note"]

      comp62 = todo_no["steps"][61]
      assert_equal "Subida Cromática!", comp62["title"]
      assert_equal 9, comp62.dig("levels", "medium", "rh").size

      comp80 = todo_no["steps"][79]
      assert_equal 80, comp80["id"]
      assert_equal "Final — D (Repouso)", comp80["title"]
    end

    test "exports all 8 native songs in the catalog and all pass SongSchema validation" do
      all_songs = Songs::NativeCatalog.all
      expected_slugs = %w[
        todo-no
        alabama-song
        bach-prelude-c
        hallelujah
        country-roads
        binks-sake
        sadness-sorrow
        rocket-man
      ]

      assert_equal expected_slugs, all_songs.keys

      all_songs.each do |slug, payload|
        result = Songs::SchemaValidator.validate(payload)
        assert result.valid?, "Expected native song '#{slug}' to pass SongSchema validation, errors: #{result.errors.first(5).join(', ')}"
      end
    end
  end
end
