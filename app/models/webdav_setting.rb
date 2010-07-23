class WebdavSetting < ActiveRecord::Base
  belongs_to :project

  def self.find_or_create(pj_id)
    setting = WebdavSetting.find(:first, :conditions => ['project_id = ?', pj_id])
    unless setting
      setting = WebdavSetting.new
      setting.project_id = pj_id
      setting.files_enabled = true
      setting.documents_enabled = true
      setting.subversion_enabled = false
      setting.subversion_only = false
      setting.files_label = "files"
      setting.documents_label = "documents"
      setting.subversion_label = "subversion"
      setting.macosx_write = false
      setting.save!      
    end
    return setting
  end
end
