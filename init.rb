#WebDav plugin for REDMINE
require 'redmine'
require File.dirname(__FILE__) + '/lib/railsdav'
require File.dirname(__FILE__) + '/lib/webdav_projects_helper_patch'
require File.dirname(__FILE__) + '/lib/webdav_subversion_adapter_patch'
ActionController::Base.send(:extend, Railsdav::Acts::Webdav::ActMethods)
#WebDAV methods
WEBDAV_HTTP_METHODS = %w(propfind mkcol move copy lock unlock options delete put proppatch) #you can add other methods here
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
  version '0.1.0'
  
  project_module :webdav do
    permission :webdav_access, :webdav => :webdav
    permission :webdav_settings, {:webdav_settings => [:show, :update]}
  end

end