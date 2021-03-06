# WebDAV plugin - Copyright (c) 2010 Arnaud Martel
# Released under the GPL License.  See the LICENSE file for more details.
require 'redmine'

require 'railsdav'
Dir::foreach(File.join(File.dirname(__FILE__), 'lib')) do |file|
  next unless /\.rb$/ =~ file
  require file
end

ActionController::Base.send(:extend, Railsdav::Acts::Webdav::ActMethods)
#WebDAV methods
WEBDAV_HTTP_METHODS = %w(propfind mkcol move copy lock unlock options delete put proppatch userinfo) #you can add other methods here
WEBDAV_HTTP_METHODS.each do |method|
  ActionController::Routing::HTTP_METHODS << method.to_sym
end
WEBDAV_HTTP_METHOD_LOOKUP = WEBDAV_HTTP_METHODS.inject({}) { |h, m| h[m] = h[m.upcase] = m.to_sym; h }
ActionController::Request::HTTP_METHODS.concat(WEBDAV_HTTP_METHODS)
ActionController::Request::HTTP_METHOD_LOOKUP.merge!(WEBDAV_HTTP_METHOD_LOOKUP)

Redmine::Plugin.register :redmine_webdav do
  name 'WebDav plugin'
  author 'Arnaud Martel'
  description 'WebDav plugin for managing files inside projects'
  version '0.6.0'
  requires_redmine :version_or_higher => '2.3.0'

  settings :default => {'webdav_file_enabled' => 1, 'webdav_document_enabled' => 1, 'webdav_repository_enabled' => 1}, :partial => 'webdav_settings/settings'
    
  project_module :webdav do
    permission :webdav_access, :webdav => :webdav
    permission :webdav_settings, {:webdav_settings => [:show, :update]}
  end

end