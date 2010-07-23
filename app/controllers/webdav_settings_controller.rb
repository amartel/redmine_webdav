# Wiki Extensions plugin for Redmine
# Copyright (C) 2009  Haruyuki Iida
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

class WebdavSettingsController < ApplicationController
  unloadable
  layout 'base'

  before_filter :find_project, :authorize, :find_user

  def update    
    menus = params[:menus]

    files_enabled = (params[:setting][:files_enabled].to_i == 1)
    documents_enabled = (params[:setting][:documents_enabled].to_i == 1)
    subversion_enabled = (params[:setting][:subversion_enabled].to_i == 1)
    subversion_only = (params[:setting][:subversion_only].to_i == 1)
    macosx_write = (params[:setting][:macosx_write].to_i == 1)
    setting = WebdavSetting.find_or_create @project.id
    begin
      setting.transaction do
        setting.files_enabled = files_enabled
        setting.documents_enabled = documents_enabled
        setting.subversion_enabled = subversion_enabled
        setting.subversion_only = subversion_only
        setting.macosx_write = macosx_write
        setting.files_label = params[:setting][:files_label].empty? ? "files" : params[:setting][:files_label]
        setting.documents_label = params[:setting][:documents_label].empty? ? "documents" : params[:setting][:documents_label]
        setting.subversion_label = params[:setting][:subversion_label].empty? ? "subversion" : params[:setting][:subversion_label]
        setting.save!
      end
      flash[:notice] = l(:notice_successful_update)
    rescue
      flash[:error] = "Updating failed."
    end
    
    redirect_to :controller => 'projects', :action => "settings", :id => @project, :tab => 'webdav'
  end

  private
  def find_project
    # @project variable must be set before calling the authorize filter
    @project = Project.find(params[:id])
  end

  def find_user
    @user = User.current
  end
end
