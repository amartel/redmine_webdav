class CreateLocks < ActiveRecord::Migration
  def self.up
    create_table :locks do |t|
      t.column :uid, :text
      t.column :timestamp, :datetime
      t.column :ipaddress, :string
      t.column :locktype, :string
      t.column :lockscope, :string
      t.column :owner, :string
      t.column :resource, :text
    end
  end

  def self.down
    drop_table :locks
  end
end
