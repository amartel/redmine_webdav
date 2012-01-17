ActionController::Routing::Routes.draw do |map|

  map.connect 'webdav', :controller  => 'webdav', :action => 'rootwebdav'
  map.connect 'webdav/:id/*path_info', :controller  => 'webdav', :action => 'webdav'
  map.connect 'webdav/*path_info', :controller  => 'webdav', :action => 'webdavnf'

  map.connect 'projects/:id/webdav_settings/:action', :controller => 'webdav_settings'
end
