match 'webdav', :controller  => 'webdav', :action => 'rootwebdav'
match 'webdav/*path_info', :controller  => 'webdav', :action => 'webdav', :format => false

match 'projects/:id/webdav_settings/:action', :controller => 'webdav_settings'
