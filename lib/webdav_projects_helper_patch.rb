# WebDAV plugin - Copyright (c) 2010 Arnaud Martel
# Released under the GPL License.  See the LICENSE file for more details.

require_dependency 'projects_helper'

module WebdavProjectsHelperPatch
  def self.included(base) # :nodoc:
    base.send(:include, ProjectsHelperMethodsWebdav)

    base.class_eval do
      unloadable # Send unloadable so it will not be unloaded in development

      alias_method_chain :project_settings_tabs, :webdav
    end

  end
end

module ProjectsHelperMethodsWebdav
  def project_settings_tabs_with_webdav
    tabs = project_settings_tabs_without_webdav
    action = {:name => 'webdav', :controller => 'webdav_settings', :action => :show, :partial => 'webdav_settings/show', :label => :webdav}

    tabs << action if User.current.allowed_to?(action, @project)

    tabs
  end
end

ProjectsHelper.send(:include, WebdavProjectsHelperPatch)
