class StudioController < ApplicationController
  def show
    Songs::NativeCatalog.seed_all! if Song.native.count < Songs::NativeCatalog.slugs.size

    @native_songs = Song.native.ready.order(:id)
    @imported_songs = Song.imported.order(created_at: :desc)
    @importing_song = Song.find_by(slug: params[:importing]) if params[:importing].present?
    @active_song = Song.ready.find_by(slug: params[:song] || "todo-no") || @native_songs.first
    @catalog_map = Song.ready.each_with_object({}) do |song, acc|
      acc[song.slug] = song.payload
    end
  end
end
