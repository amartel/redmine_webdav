# Copyright (c) 2006 Stuart Eccles
# Released under the MIT License.  See the LICENSE file for more details.
#
# WebDAV plugin - Copyright (c) 2010 Arnaud Martel
# Released under the GPL License.  See the LICENSE file for more details.


#require 'shared-mime-info'
require 'mime/types'
require 'tmpdir'
require 'fileutils'

module Railsdav
  class FileResource
    include Resource

    WEBDAV_PROPERTIES = [ :displayname, :creationdate, :getlastmodified,
      :getetag, :getcontenttype, :getcontentlength ]

    class_attribute :file_options

    self.file_options = {
      :base_url => '',
      :max_propfind_depth => 1
    }

    def initialize(*args)
      #Rails.logger.error "New FileResource for #{args[1]}"      
      @project = args.first
      @setting ||= WebdavSetting.find_or_create @project.id
      @fullpath=args[1].split("/")
      @href = args[2]
      @container = nil
      @container = args[3] if args[3]
      @file = nil
      @file = args[4] if args[4]
      @level = @fullpath.length
      @isdir = true
      @repository = nil
      if @level == 0
        @container = @project
      elsif @setting.only_repository?
        @repository = @setting.tab_repos.length == 0 ? @project.repository : @project.repositories.find_by_identifier_param(@setting.tab_repos[0])
        @container = nil
        @container = args[4] if args[4]
        @container ||=  @repository.entry(FileResource.scm_path(@repository, args[1]), @repository.default_branch)
        if @container
          @isdir = @container.is_dir?
          @stat = @container
          if !@isdir
            @file = @container
          end
        end
      elsif @setting.subversion_only
        if @level == 1
          @container = @fullpath[0]
        else
          @repository = @project.repositories.find_by_identifier_param(@fullpath[0])
          @container = nil
          @container = args[4] if args[4]
          @container ||=  @repository.entry(FileResource.scm_path(@repository, args[1][(@repository.identifier.length + 1)..-1]), @repository.default_branch)
          if @container
            @isdir = @container.is_dir?
            @stat = @container
            if !@isdir
              @file = @container
            end
          end
        end
      elsif @level == 1
        if @fullpath[0] == @setting.files_label
          @container = "files"
        elsif @fullpath[0] == @setting.documents_label
          @container = "documents"
        elsif @fullpath[0] == @setting.subversion_label
          @container = "scm"
        end
      elsif @fullpath[0] == @setting.subversion_label
        if @setting.show_id?
          id_repo = @fullpath[1]
          @repository = @project.repositories.find_by_identifier_param(id_repo)
        else
          id_repo = @setting.tab_repos[0]
          @repository = @setting.tab_repos.length == 0 ? @project.repository : @project.repositories.find_by_identifier_param(@setting.tab_repos[0])
        end
        if @level == 2 && @setting.show_id?
          @container = id_repo
        else
          @container = nil
          @container = args[4] if args[4]
          @container ||=  @repository.entry(FileResource.scm_path(@repository, args[1][(@setting.subversion_label.length + (@setting.show_id? ? @repository.identifier.length : 0) + 1)..-1]), @repository.default_branch)
          if @container
            @isdir = @container.is_dir?
            @stat = @container
            if !@isdir
              @file = @container
            end
          end
        end
      else
        if @level > 1
          if @fullpath[0] == @setting.files_label
            @container ||= @project.versions.find_by_name(@fullpath[1])
            if !@container && @level==2
              @file ||= @project.attachments.find(:first, :conditions => [ "filename = ?", @fullpath[1] ])
              @container = @project
              @isdir = false
            end
          elsif @fullpath[0] == @setting.documents_label
            @container ||= @project.documents.find_by_title(@fullpath[1])
          end
        end
        if @level > 2 && @fullpath[0] != @setting.subversion_label
          @isdir = false
          if @container
            @file ||= @container.attachments.find(:first, :conditions => [ "filename = ?", @fullpath[2] ])
          end
        end
      end
      if !@isdir && @file && @fullpath[0] != @setting.subversion_label && !@setting.subversion_only
        @stat = File.lstat(@file.diskfile)
      end
      if args.last.is_a?(String)
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
        if @setting.only_repository?
          repository = @setting.tab_repos.length == 0 ? @project.repository : @project.repositories.find_by_identifier_param(@setting.tab_repos[0])
          repository.entries(FileResource.scm_path(repository, "/"), repository.default_branch).each do |entry|
            resources << self.class.new(@project, entry.name, File.join(@href, FileResource.escape(entry.name)), nil, entry)
          end
        elsif @setting.subversion_only 
          @setting.tab_repos.each do |r|
            resources << self.class.new(@project, r, File.join(@href, r))
          end
        else
          resources << self.class.new(@project, @setting.files_label, File.join(@href, FileResource.escape(@setting.files_label))) if (@setting.files_enabled && User.current.allowed_to?(:view_files, @project))
          resources << self.class.new(@project, @setting.documents_label, File.join(@href, FileResource.escape(@setting.documents_label))) if (@setting.documents_enabled && User.current.allowed_to?(:view_documents, @project))
          resources << self.class.new(@project, @setting.subversion_label, File.join(@href, FileResource.escape(@setting.subversion_label))) if (@setting.subversion_enabled && User.current.allowed_to?(:browse_repository, @project))
        end
      when 1
        if @setting.only_repository?
          if @isdir && @container.is_a?(Redmine::Scm::Adapters::Entry)
            @repository.entries(FileResource.scm_path(@repository, @container.path), @repository.default_branch).each do |entry|
              resources << self.class.new(@project, File.join("/", @container.path, entry.name), File.join(@href, FileResource.escape(entry.name)), nil, entry)
            end
          end
        elsif @setting.subversion_only 
          repository = @project.repositories.find_by_identifier_param(@container)
          repository.entries(FileResource.scm_path(repository, "/"), repository.default_branch).each do |entry|
            resources << self.class.new(@project, File.join(@container, entry.name), File.join(@href, FileResource.escape(entry.name)), nil, entry)
          end
        else
          if @container == "files"
            @project.versions.each do |version|
              resources << self.class.new(@project, File.join(@setting.files_label, version.name), File.join(@href, FileResource.escape(version.name)), nil, version)
            end
            @project.attachments.each do |attach|
              resources << self.class.new(@project, File.join(@setting.files_label, attach.filename), File.join(@href, FileResource.escape(attach.filename)), nil, attach)
            end
          elsif @container == "documents"
            @project.documents.each do |document|
              resources << self.class.new(@project, File.join(@setting.documents_label, document.title), File.join(@href, FileResource.escape(document.title)), nil, document)
            end
          elsif @container == "scm"
            if @setting.show_id?
              #List selected repositories
              @setting.tab_repos.each do |r|
                resources << self.class.new(@project, File.join(@setting.subversion_label, r), File.join(@href, FileResource.escape(@setting.subversion_label), r))
              end
            else
              repository = @setting.tab_repos.length == 0 ? @project.repository : @project.repositories.find_by_identifier_param(@setting.tab_repos[0])
              repository.entries(FileResource.scm_path(repository, "/"), repository.default_branch).each do |entry|
                resources << self.class.new(@project, File.join(@setting.subversion_label, entry.name), File.join(@href, FileResource.escape(@setting.subversion_label), FileResource.escape(entry.name)), nil, entry)
              end
            end
          end
        end
      when 2
        if @isdir
          if @container.is_a?(Redmine::Scm::Adapters::Entry) || @container.is_a?(String)
            svnpath = ""
            if @setting.only_repository?
              svnpath = "/"
            elsif @setting.subversion_only
              svnpath = @fullpath[0]
            elsif @setting.show_id?
              svnpath = File.join(@setting.subversion_label, @fullpath[1])
            else
              svnpath = @setting.subversion_label
            end
            repo_path = @container.is_a?(Redmine::Scm::Adapters::Entry) ? @container.path : ""
            @repository.entries(FileResource.scm_path(@repository, repo_path), @repository.default_branch).each do |entry|
              resources << self.class.new(@project, File.join(svnpath, repo_path, entry.name), File.join(@href, FileResource.escape(entry.name)), nil, entry)
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
              resources << self.class.new(@project, File.join(root,foldername,attach.filename), File.join(@href, FileResource.escape(attach.filename)), @container, attach)
            end
          end
        end
      else
        if @isdir && @container.is_a?(Redmine::Scm::Adapters::Entry)
          svnpath = ""
          if @setting.only_repository?
            svnpath = "/"
          elsif @setting.subversion_only
            svnpath = @fullpath[0]
          elsif @setting.show_id?
            svnpath = File.join(@setting.subversion_label, @fullpath[1])
          else
            svnpath = @setting.subversion_label
          end
          @repository.entries(FileResource.scm_path(@repository, @container.path), @repository.default_branch).each do |entry|
            resources << self.class.new(@project, File.join(svnpath, @container.path, entry.name), File.join(@href, FileResource.escape(entry.name)), nil, entry)
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
        elsif @container.is_a?(String)
          @container
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
      if !@container.is_a?(String)
        if @container.is_a?(Redmine::Scm::Adapters::Entry)
          cdate = @container.lastrev.time
        elsif @level > 1
          if @isdir
            cdate = @container.created_on
          else
            cdate = @stat.ctime
          end
        end
      end
      cdate.xmlschema
    end

    def getlastmodified
      cdate = @project.updated_on
      if !@container.is_a?(String)
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
        elsif @container.is_a?(String)
          sprintf('%x-%x-%x', (@project.id * (10**@level)) + @container.length, 0, @project.updated_on.to_i)
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
        mimetype = MIME::Types.type_for(displayname)
        (mimetype.nil? || mimetype.empty?) ? "application/octet-stream" : mimetype.first
      end
    end

    def getcontentlength
      collection? ? nil : @stat.size
    end

    def data
      if ! @isdir
        if @container.is_a?(Redmine::Scm::Adapters::Entry)
          @repository.cat(FileResource.scm_path(@repository, @container.path), @repository.default_branch)
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
          if @repository.scm.respond_to?('webdav_delete')
            @repository.scm.webdav_delete(@repository, FileResource.scm_path(@repository, @container.path), "deleted #{File.basename(@container.path)}", nil)
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
        svnpath = ""
        if setting.only_repository?
          svnpath = ""
          repository = setting.tab_repos.length == 0 ? project.repository : project.repositories.find_by_identifier_param(setting.tab_repos[0])
        elsif setting.subversion_only
          svnpath = pinfo[0]
          repository = project.repositories.find_by_identifier_param(pinfo[0])
        elsif setting.show_id?
          svnpath = File.join(setting.subversion_label, pinfo[1])
          repository = project.repositories.find_by_identifier_param(pinfo[1])
        else
          svnpath = setting.subversion_label
          repository = setting.tab_repos.length == 0 ? project.repository : project.repositories.find_by_identifier_param(setting.tab_repos[0])
        end
        if repository.scm.respond_to?('webdav_mkdir')
          repository.scm.webdav_mkdir(repository, self.scm_path(project, path[(svnpath.length)..-1]), "added #{File.basename(path)}", nil)
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
        svnpath = ""
        if setting.only_repository?
          svnpath = ""
          repository = setting.tab_repos.length == 0 ? project.repository : project.repositories.find_by_identifier_param(setting.tab_repos[0])
        elsif setting.subversion_only
          svnpath = pinfo[0]
          repository = project.repositories.find_by_identifier_param(pinfo[0])
        elsif setting.show_id?
          svnpath = File.join(setting.subversion_label, pinfo[1])
          repository = project.repositories.find_by_identifier_param(pinfo[1])
        else
          svnpath = setting.subversion_label
          repository = setting.tab_repos.length == 0 ? project.repository : project.repositories.find_by_identifier_param(setting.tab_repos[0])
        end
        container =  repository.entry(path[(svnpath.length)..-1], nil)
        comments = container.nil? ? "added #{File.basename(path)}" : "updated #{File.basename(path)}"
        if repository.scm.respond_to?('webdav_upload')
          repository.scm.webdav_upload(repository, self.scm_path(project, path[(svnpath.length)..-1]), content, comments, nil)
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
          
          tmpfile = Tempfile.new(pinfo.last)
          tmpfile.binmode
          tmpfile.write(content)
          tmpfile.rewind
          uploaded_file = ActionDispatch::Http::UploadedFile.new({:filename => pinfo.last, :tempfile => tmpfile})
          
          a = Attachment.create(:container => container,
          :webdavfile => uploaded_file,
          :description => "",
          :author => User.current)
          if a.new_record?
            #a.save
            raise InsufficientStorageError
          end
          tmpfile.close!
          Mailer.deliver_attachments_added([ a ])
        end
      end
    end

    def move_to_path(dest_path, depth)
      pinfo = dest_path.split("/")
      if @container.is_a?(Redmine::Scm::Adapters::Entry)
        svnpath = ""
        if @setting.only_repository?
          svnpath = ""
        elsif @setting.subversion_only
          svnpath = @fullpath[0]
        elsif @setting.show_id?
          svnpath = File.join(@setting.subversion_label, @fullpath[1])
        else
          svnpath = @setting.subversion_label
        end

        #Test if source and destination are in the same repository
        if dest_path =~ /^#{svnpath}\//
          if @repository.scm.respond_to?('webdav_move')
            @repository.scm.webdav_move(@repository, FileResource.scm_path(@repository, @container.path), FileResource.scm_path(@repository, dest_path[(svnpath.length)..-1]), "moved/renamed #{File.basename(dest_path)}", nil)
          end
        else
          recurse_copy(dest_path)
          delete!
        end
      else
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
        svnpath = ""
        if @setting.only_repository?
          svnpath = ""
        elsif @setting.subversion_only
          svnpath = @fullpath[0]
        elsif @setting.show_id?
          svnpath = File.join(@setting.subversion_label, @fullpath[1])
        else
          svnpath = @setting.subversion_label
        end
        if dest_path =~ /^#{svnpath}\//
          if @repository.scm.respond_to?('webdav_copy')
            @repository.scm.webdav_copy(@repository, FileResource.scm_path(@repository, @container.path), FileResource.scm_path(@repository, dest_path[(svnpath.length)..-1]), "copied #{File.basename(dest_path)}", nil)
          end
        else
          recurse_copy(dest_path)
        end
      else
        raise ForbiddenError unless !@isdir
        self.class.do_file_action do
          self.class.write_content_to_path(@project, dest_path, filecontent)
        end
      end
    end

    def recurse_copy(dest_path)
      pinfo = dest_path.split("/")
      if @container.is_a?(Redmine::Scm::Adapters::Entry)
        svnpath = ""
        if @setting.only_repository?
          svnpath = ""
        elsif @setting.subversion_only
          svnpath = @fullpath[0]
        elsif @setting.show_id?
          svnpath = File.join(@setting.subversion_label, @fullpath[1])
        else
          svnpath = @setting.subversion_label
        end
        fpj = @fullpath.join('/')
        root_url = @href.gsub(/#{fpj}/,'').chomp('/')
        dest_ress = self.class.new(@project, dest_path, File.join(root_url, dest_path))
        if !@isdir
          FileResource.write_content_to_path(@project, dest_path, data)
        else
          if !(dest_ress && dest_ress.valid?)
            FileResource.mkcol_for_path(@project, dest_path)
          end
          children.each do |it|
            it.recurse_copy(File.join(dest_path, it.lastname))
          end
        end
      end
    end
    
    def lastname
      @fullpath[-1]
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
    def self.scm_path(repository, path)
      ret = path
      if repository.is_a?(Repository::Subversion)
        ret = without_leading_slash(path)
      end
      if repository.is_a?(Repository::Filesystem)
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
