class WebdavController < ApplicationController

  acts_as_webdav :resource_model => Webdav

  before_filter :find_project, :authorize, :find_user

  private
  def find_project
    # @project variable must be set before calling the authorize filter
    if params[:id]
       @project = Project.find(params[:id])
    end
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_user
    User.current = find_current_user
    @user = User.current
  end

  # Authorize the user for the requested action
  def authorize(ctrl = params[:controller], action = params[:action], global = false)
    case action
    when "rootwebdav", "webdavnf"
      allowed = true
    else
      allowed = User.current.allowed_to?({:controller => ctrl, :action => action}, @project, :global => global)
    end
    allowed ? true : deny_access
  end
    
end
