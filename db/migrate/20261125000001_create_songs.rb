class CreateSongs < ActiveRecord::Migration[8.1]
  def change
    create_table :songs do |t|
      t.string :slug, null: false
      t.string :title, null: false
      t.string :artist
      t.string :source_type, null: false, default: "native"
      t.string :source_url
      t.string :status, null: false, default: "processing"
      t.text :error_message
      t.string :key_signature, default: "C"
      t.integer :default_bpm, default: 76
      t.string :time_signature, default: "4/4"
      t.integer :total_measures, default: 0
      t.json :payload, null: false, default: {}

      t.timestamps
    end

    add_index :songs, :slug, unique: true
    add_index :songs, :source_type
    add_index :songs, :status
  end
end
