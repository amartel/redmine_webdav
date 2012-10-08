# WebDAV plugin - Copyright (c) 2010 Arnaud Martel
# Released under the GPL License.  See the LICENSE file for more details.
class WebdavSetting < ActiveRecord::Base
  belongs_to :project

  def self.find_or_create(pj_id)
    setting = WebdavSetting.find(:first, :conditions => ['project_id = ?', pj_id])
    unless setting
      setting = WebdavSetting.new
      setting.project_id = pj_id
      setting.files_enabled = Setting.plugin_redmine_webdav['webdav_file_enabled']
      setting.documents_enabled = Setting.plugin_redmine_webdav['webdav_document_enabled']
      setting.subversion_enabled = Setting.plugin_redmine_webdav['webdav_repository_enabled']
      setting.subversion_only = Setting.plugin_redmine_webdav['webdav_repo_only']
      setting.files_label = Setting.plugin_redmine_webdav['webdav_file_label'].blank? ? l(:files_label) : Setting.plugin_redmine_webdav['webdav_file_label']
      setting.documents_label = Setting.plugin_redmine_webdav['webdav_document_label'].blank? ? l(:documents_label) : Setting.plugin_redmine_webdav['webdav_document_label']
      setting.subversion_label = Setting.plugin_redmine_webdav['webdav_repository_label'].blank? ? l(:subversion_label) : Setting.plugin_redmine_webdav['webdav_repository_label']
      setting.macosx_write = Setting.plugin_redmine_webdav['webdav_macosx']
      setting.show_identifier = true
      setting.save!      
    end
    return setting
  end
  
  def tab_repos
    ret = []
    ret = repos.split(/\n/).delete_if{|x| x == ""} unless repos.nil?
    return ret
  end

  def only_repository?
    subversion_only && subversion_enabled && tab_repos.length <= 1 && !show_identifier
  end
  
  def show_id?
    tab_repos.length > 0 && ( show_identifier || tab_repos.length > 1 )
  end
end
