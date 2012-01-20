# Copyright (c) 2006 Stuart Eccles
# Released under the MIT License.  See the LICENSE file for more details.

# The base_dir parameter can be a string for a directory or a symbol for a method which is run for every
# request allowing the base directory to be changed based on the request
#
# If the parameter :absolute = true the :base_dir setting will be treated as an absolute path, otherwise
# the it will be taken as a directory underneath the RAILS_ROOT
#

require 'shared-mime-info'
require 'tmpdir'
require 'fileutils'

module Railsdav
  class FileResource
    include Resource

    WEBDAV_PROPERTIES = [ :displayname, :creationdate, :getlastmodified,
      :getetag, :getcontenttype, :getcontentlength ]

    class_inheritable_accessor :file_options

    self.file_options = {
      :base_url => '',
      :max_propfind_depth => 1
    }

    def initialize(*args)
      #RAILS_DEFAULT_LOGGER.info "Dans fileresource.initialize projectname= #{@project.name}"
      @href=""
      @project = args.first
      @setting = WebdavSetting.find_or_create @project.id
      pinfo=args[1].split("/")
      @level = pinfo.length
      @isdir = true
      if @level == 0
        @container = @project
      end
      if @setting.subversion_only && @level > 0
        @container =  @project.repository.entry(FileResource.scm_path(@project, args[1]), @project.repository.default_branch)
        if @container
          @isdir = @container.is_dir?
          @stat = @container
          if !@isdir
            @file = @container
          end
        end
      else
        if @level == 1
          if pinfo[0] == @setting.files_label
            @container = "files"
          elsif pinfo[0] == @setting.documents_label
            @container = "documents"
          elsif pinfo[0] == @setting.subversion_label
            @container = "scm"
          end
        end
        if @level > 1
          if pinfo[0] == @setting.files_label
            @container = @project.versions.find_by_name(pinfo[1])
            if !@container && @level==2
              @file = @project.attachments.find(:first, :conditions => [ "filename = ?", pinfo[1] ])
              @container = @project
              @isdir = false
            end
          elsif pinfo[0] == @setting.documents_label
            @container = @project.documents.find_by_title(pinfo[1])
          elsif pinfo[0] == @setting.subversion_label
            @container =  @project.repository.entry(FileResource.scm_path(@project, args[1][(@setting.subversion_label.length)..-1]), @project.repository.default_branch)
            if @container
              @isdir = @container.is_dir?
              @stat = @container
              if !@isdir
                @file = @container
              end
            end
          end
        end
        if @level > 2 && pinfo[0] != @setting.subversion_label
          @isdir = false
          if @container
            @file = @container.attachments.find(:first, :conditions => [ "filename = ?", pinfo[2] ])
          end
        end
      end
      if !@isdir && @file && pinfo[0] != @setting.subversion_label && !@setting.subversion_only
        @stat = File.lstat(@file.diskfile)
      end
      if args.last.is_a?(String)
        @href = args.last
        @href = File.join(@href, '') if collection?
      end
    end

    def self.initialize_by_path_and_href(project, path, href)
      do_file_action do
        r = new(project, path, FileResource.specialchar(href))
        r if r.valid?
      end
    end

    def collection?
      @isdir
    end

    def valid?
      (@isdir && @container) || @file
    end

    def children
      resources = []
      case @level
      when 0
        if (@setting.subversion_only && @setting.subversion_enabled)
          @project.repository.entries(FileResource.scm_path(@project, "/"), @project.repository.default_branch).each do |entry|
            resources << self.class.new(@project, entry.name, File.join(@href, FileResource.escape(entry.name)))
          end
        else
          resources << self.class.new(@project, @setting.files_label, File.join(@href, FileResource.escape(@setting.files_label))) if (@setting.files_enabled && User.current.allowed_to?(:view_files, @project))
          resources << self.class.new(@project, @setting.documents_label, File.join(@href, FileResource.escape(@setting.documents_label))) if (@setting.documents_enabled && User.current.allowed_to?(:view_documents, @project))
          resources << self.class.new(@project, @setting.subversion_label, File.join(@href, FileResource.escape(@setting.subversion_label))) if (@setting.subversion_enabled && User.current.allowed_to?(:browse_repository, @project))
        end
      when 1
        if (@setting.subversion_only && @setting.subversion_enabled)
          if @isdir && @container.is_a?(Redmine::Scm::Adapters::Entry)
            @project.repository.entries(FileResource.scm_path(@project, @container.path), @project.repository.default_branch).each do |entry|
              resources << self.class.new(@project, File.join("/", @container.path, entry.name), File.join(@href, FileResource.escape(entry.name)))
            end
          end
        else
          if @container == "files"
            @project.versions.each do |version|
              resources << self.class.new(@project, File.join(@setting.files_label, version.name), File.join(@href, FileResource.escape(version.name)))
            end
            @project.attachments.each do |attach|
              resources << self.class.new(@project, File.join(@setting.files_label, attach.filename), File.join(@href, FileResource.escape(attach.filename)))
            end
          elsif @container == "documents"
            @project.documents.each do |document|
              resources << self.class.new(@project, File.join(@setting.documents_label, document.title), File.join(@href, FileResource.escape(document.title)))
            end
          elsif @container == "scm"
            @project.repository.entries(FileResource.scm_path(@project, "/"), @project.repository.default_branch).each do |entry|
              resources << self.class.new(@project, File.join(@setting.subversion_label, entry.name), File.join(@href, FileResource.escape(entry.name)))
            end
          end
        end
      when 2
        if @isdir
          if @container.is_a?(Redmine::Scm::Adapters::Entry)
            svnpath = @setting.subversion_only ? "/" : @setting.subversion_label
            @project.repository.entries(FileResource.scm_path(@project, @container.path), @project.repository.default_branch).each do |entry|
              resources << self.class.new(@project, File.join(svnpath, @container.path, entry.name), File.join(@href, FileResource.escape(entry.name)))
            end
          else
            if @container.is_a?(Document)
              foldername = @container.title
              root=@setting.documents_label
            else
              foldername = @container.name
              root=@setting.files_label
            end
            @container.attachments.each do |attach|
              resources << self.class.new(@project, File.join(root,foldername,attach.filename), File.join(@href, FileResource.escape(attach.filename)))
            end
          end
        end
      else
        if @isdir && @container.is_a?(Redmine::Scm::Adapters::Entry)
          svnpath = @setting.subversion_only ? "/" : @setting.subversion_label
          @project.repository.entries(FileResource.scm_path(@project, @container.path), @project.repository.default_branch).each do |entry|
            resources << self.class.new(@project, File.join(svnpath, @container.path, entry.name), File.join(@href, FileResource.escape(entry.name)))
          end
        end
      end
      resources
    end

    def properties
      props = {}
      WEBDAV_PROPERTIES.each do |method|
        props[method] = send(method) if respond_to?(method)
      end
      props
    end

    def displayname
      case @level
      when 0
        FileResource.specialchar(@project.name)
      when 1
        if @container.is_a?(Redmine::Scm::Adapters::Entry)
          FileResource.specialchar(@container.name)
        else
          @container
        end
      else
        if @container.is_a?(Redmine::Scm::Adapters::Entry)
          FileResource.specialchar(@container.name)
        elsif @isdir
          if @container.is_a?(Document)
            @container.title
          else
            @container.name
          end
        else
          @file.filename
        end
      end
    end

    def creationdate
      cdate = @project.created_on
      if @container.is_a?(Redmine::Scm::Adapters::Entry)
        cdate = @container.lastrev.time
      elsif @level > 1
        if @isdir
          cdate = @container.created_on
        else
          cdate = @stat.ctime
        end
      end
      cdate.xmlschema
    end

    def getlastmodified
      cdate = @project.updated_on
      if @container.is_a?(Redmine::Scm::Adapters::Entry)
        cdate = @container.lastrev.time
      elsif @level > 1
        if @isdir
          if @container.is_a?(Version)
            cdate = @container.updated_on
          end
        else
          cdate = @stat.mtime
        end
      end
      cdate.httpdate
    end

    def getetag
      case @level
      when 0
        sprintf('%x-%x-%x', @project.id, 0, @project.updated_on.to_i)
      when 1
        if @container.is_a?(Redmine::Scm::Adapters::Entry)
          sprintf('%x-%x-%x', @container.size, 0, @container.lastrev.time.to_i)
        else
          sprintf('%x-%x-%x', (@project.id * 10) + @container.length, 0, @project.updated_on.to_i)
        end
      else
        if @container.is_a?(Redmine::Scm::Adapters::Entry)
          sprintf('%x-%x-%x', @container.size, 0, @container.lastrev.time.to_i)
        elsif @isdir
          if @container.is_a?(Version)
            sprintf('%x-%x-%x', @container.id, 0, @container.updated_on.to_i)
          else
            sprintf('%x-%x-%x', @container.id, 0, @container.created_on.to_i)
          end
        else
          sprintf('%x-%x-%x', @file.id, @file.filesize, @file.created_on.to_i)
        end
      end
    end

    def getcontenttype
      if collection?
        "httpd/unix-directory"
      else
        mimetype = MIME.check_globs(displayname).to_s
        mimetype.blank? ? "application/octet-stream" : mimetype
      end
    end

    def getcontentlength
      collection? ? nil : @stat.size
    end

    def data
      if ! @isdir
        if @container.is_a?(Redmine::Scm::Adapters::Entry)
          @project.repository.cat(FileResource.scm_path(@project, @container.path), @project.repository.default_branch)
        else
          File.new(@file.diskfile)
        end
      end
    end

    def filecontent
      if ! @isdir
        File.open(@file.diskfile, 'rb') { |f| f.read }
      end
    end

    def delete!
      self.class.do_file_action do
        if @container.is_a?(Redmine::Scm::Adapters::Entry)
          if @project.repository.scm.respond_to?('webdav_delete')
            @project.repository.scm.webdav_delete(@project, FileResource.scm_path(@project, @container.path), "deleted #{File.basename(@container.path)}", nil)
          end
        elsif @file
          @container.attachments.delete(@file)
        elsif @container.is_a?(Document)
          @container.destroy
        end
      end
    end

    def self.mkcol_for_path(project, path)
      #Create directory
      pinfo = path.split("/")
      setting = WebdavSetting.find_or_create project.id
      if (pinfo[0] == setting.subversion_label || setting.subversion_only)
        svnpath = setting.subversion_only ? "" : setting.subversion_label
        if project.repository.scm.respond_to?('webdav_mkdir')
          project.repository.scm.webdav_mkdir(project, self.scm_path(project, path[(svnpath.length)..-1]), "added #{File.basename(path)}", nil)
        end
      else
        raise ForbiddenError unless pinfo.length == 2
        raise ForbiddenError unless pinfo[0] == setting.documents_label
        container = project.documents.find_by_title(pinfo[1])
        if !container
          @doc = project.documents.build({ :title => pinfo[1],
            :description => 'Created from WEBDAV',
            :category_id => DocumentCategory.first.id})
          @doc.save
        end
      end
    end

    def self.write_content_to_path(project, path, content)
      #Create a file
      pinfo = path.split("/")
      setting = WebdavSetting.find_or_create project.id
      if (pinfo[0] == setting.subversion_label || setting.subversion_only)
        svnpath = setting.subversion_only ? "" : setting.subversion_label
        container =  project.repository.entry(path[(svnpath.length)..-1], nil)
        comments = container.nil? ? "added #{File.basename(path)}" : "updated #{File.basename(path)}"
        if project.repository.scm.respond_to?('webdav_upload')
          project.repository.scm.webdav_upload(project, self.scm_path(project, path[(svnpath.length)..-1]), content, comments, nil)
        end
      else
        case pinfo.length
        when 2
          if pinfo[0] == setting.files_label
            container = project
            file = project.attachments.find(:first, :conditions => [ "filename = ?", pinfo[1] ])
          end
        when 3
          if pinfo[0] == setting.files_label
            container = project.versions.find_by_name(pinfo[1])
            file = container.attachments.find(:first, :conditions => [ "filename = ?", pinfo[2] ])
          end
          if pinfo[0] == setting.documents_label
            container = project.documents.find_by_title(pinfo[1])
            file = container.attachments.find(:first, :conditions => [ "filename = ?", pinfo[2] ])
          end
        end

        if container
          if file
            container.attachments.delete(file)
          end
          uploaded_file = ActionController::UploadedTempfile.new(pinfo.last)
          uploaded_file.binmode
          uploaded_file.write(content)
          #        uploaded_file.flush
          uploaded_file.original_path = pinfo.last
          uploaded_file.rewind
          a = Attachment.create(:container => container,
          :webdavfile => uploaded_file,
          :description => "",
          :author => User.current)
          if a.new_record?
            #a.save
            raise InsufficientStorageError
          end
          uploaded_file.close!
          Mailer.deliver_attachments_added([ a ])
        end
      end
    end

    def move_to_path(dest_path, depth)
      if @container.is_a?(Redmine::Scm::Adapters::Entry)
        svnpath = @setting.subversion_only ? "" : @setting.subversion_label
        if @project.repository.scm.respond_to?('webdav_move')
          @project.repository.scm.webdav_move(@project, FileResource.scm_path(@project, @container.path), FileResource.scm_path(@project, dest_path[(svnpath.length)..-1]), "moved/renamed #{File.basename(dest_path)}", nil)
        end
      else
        pinfo = dest_path.split("/")
        raise ForbiddenError unless !@isdir || (@container.is_a?(Document) && pinfo.length == 2)
        self.class.do_file_action do
          if !@isdir
            FileResource.write_content_to_path(@project, dest_path, filecontent)
            delete!
          else
            @container.title = CGI.unescape(pinfo[1])
            @container.save
          end
        end
      end
    end

    def copy_to_path(dest_path, depth)
      if @container.is_a?(Redmine::Scm::Adapters::Entry)
        svnpath = @setting.subversion_only ? "" : @setting.subversion_label
        if @project.repository.scm.respond_to?('webdav_copy')
          @project.repository.scm.webdav_copy(@project, FileResource.scm_path(@project, @container.path), FileResource.scm_path(@project, dest_path[(svnpath.length)..-1]), "copied #{File.basename(dest_path)}", nil)
        end
      else
        raise ForbiddenError unless !@isdir
        self.class.do_file_action do
          self.class.write_content_to_path(@project, dest_path, filecontent)
        end
      end
    end

    def self.do_file_action
      begin
        yield
      rescue Errno::ENOENT, Errno::EEXIST
        raise ConflictError
      rescue Errno::EPERM, Errno::EACCES
        raise ForbiddenError
      rescue Errno::ENOSPC
        raise InsufficientStorageError
      end
    end

    def self.shell_quote(str)
      if Redmine::Platform.mswin?
        '"' + str.gsub(/"/, '\\"') + '"'
      else
        "'" + str.gsub(/'/, "'\"'\"'") + "'"
      end
    end

    def self.with_leading_slash(path)
       path ||= ''
      (path[0,1]!="/") ? "/#{path}" : path
    end
    def self.without_leading_slash(path)
      path ||= ''
      path.gsub(%r{^/+}, '')
    end
    def self.scm_path(project, path)
      ret = path
      if project.repository.is_a?(Repository::Subversion)
        ret = without_leading_slash(path)
      end
      if project.repository.is_a?(Repository::Filesystem)
        ret = with_leading_slash(path)
      end
      ret
    end
    def self.specialchar(value)
      value.gsub(/&/,"%26")
    end
    def self.escape(filename)
      specialchar(URI.escape(filename.gsub(/\+/,"@*@")).gsub(/@\*@/,"%2B"))
    end

  end
end
