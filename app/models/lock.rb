class Lock < ActiveRecord::Base
  unloadable
  validates_presence_of :uid
  validates_presence_of :timestamp
  validates_presence_of :locktype
  validates_presence_of :resource
end
