class MultiRepositories < ActiveRecord::Migration
  def self.up
    add_column(:webdav_settings, "repos", :text)
    add_column(:webdav_settings, "show_identifier", :boolean)
    execute <<-SQL
            UPDATE webdav_settings SET show_identifier = 0, repos=NULL
    SQL

  end

  def self.down
    remove_column(:webdav_settings, "repos")
    remove_column(:webdav_settings, "show_identifier")
  end
end
