# Copyright (c) 2006 Stuart Eccles
# Released under the MIT License.  See the LICENSE file for more details.

# The base_dir parameter can be a string for a directory or a symbol for a method which is run for every
# request allowing the base directory to be changed based on the request
#
# If the parameter :absolute = true the :base_dir setting will be treated as an absolute path, otherwise
# the it will be taken as a directory underneath the RAILS_ROOT
#

require 'shared-mime-info'

module Railsdav
  class FileResource
    include Resource

    @@logger = Logger.new(STDOUT)

    WEBDAV_PROPERTIES = [ :displayname, :creationdate, :getlastmodified,
      :getetag, :getcontenttype, :getcontentlength ]

    class_inheritable_accessor :file_options

    self.file_options = {
      :base_url => '',
      :max_propfind_depth => 1
    }

    def initialize(*args)
      @href=""
      @project = args.first
      #RAILS_DEFAULT_LOGGER.info "Dans fileresource.initialize projectname= #{@project.name}"
      #arg[1] : <documents | files>/<fichier | document_name | version_name> [/fichier]
      pinfo=args[1].split("/")
      @level = pinfo.length
      @isdir = true
      if @level == 0
        @container = @project
      end
      if @level == 1
        if pinfo[0] == "files"
          @container = "files"
        end
        if pinfo[0] == "documents"
          @container = "documents"
        end
      end
      if @level > 1 && pinfo[0] == "files"
        @container = @project.versions.find_by_name(pinfo[1])
      end
      if @level > 1 && pinfo[0] == "documents"
        @container = @project.documents.find_by_title(pinfo[1])
      end
      if !@container && pinfo[0] == "files" && @level==2
        @file = @project.attachments.find(:first, :conditions => [ "filename = ?", pinfo[1] ])
        @container = @project
        @isdir = false
      end
      if @level > 2
        @isdir = false
        if @container
          @file = @container.attachments.find(:first, :conditions => [ "filename = ?", pinfo[2] ])
        end
      end
      if !@isdir && @file
        @stat = File.lstat(@file.diskfile)
      end
      if args.last.is_a?(String)
        @href = args.last
        @href = File.join(@href, '') if collection?
      end
    end

    def self.initialize_by_path_and_href(project, path, href)
      do_file_action do
        r = new(project, path, href)
        r if r.valid?
      end
    end

    def collection?
      @isdir
    end

    def valid?
      (@isdir && @container) || @file
    end

    def delete!
      self.class.do_file_action do
        if @file
          @container.attachments.delete(@file)
        else
          if @container.is_a?(Document)
            @container.destroy
          end
        end
      end
    end

    def children
      resources = []
      case @level
      when 0
        resources << self.class.new(@project, "files", File.join(@href, "files")) if User.current.allowed_to?(:view_files, @project)
        resources << self.class.new(@project, "documents", File.join(@href, "documents")) if User.current.allowed_to?(:view_documents, @project)
      when 1
        if @container == "files"
          @project.versions.each do |version|
            resources << self.class.new(@project, File.join("files", version.name), File.join(@href, version.name))
          end
          @project.attachments.each do |attach|
            resources << self.class.new(@project, File.join("files", attach.filename), File.join(@href, attach.filename))
          end
        else
          @project.documents.each do |document|
            resources << self.class.new(@project, File.join("documents", document.title), File.join(@href, document.title))
          end
        end
      when 2
        if @isdir
          if @container.is_a?(Document)
            foldername = @container.title
            root="documents"
          else
            foldername = @container.name
            root="files"
          end
          @container.attachments.each do |attach|
            resources << self.class.new(@project, File.join(root,foldername,attach.filename), File.join(@href, attach.filename))
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
        @project.name
      when 1
        @container
      else
        if @isdir
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
      if @level > 1
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
      if @level > 1
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
        sprintf('%x-%x-%x', (@project.id * 10) + @container.length, 0, @project.updated_on.to_i)
      else
        if @isdir
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
        File.new(@file.diskfile)
      end
    end

    def filecontent
      if ! @isdir
        File.open(@file.diskfile, 'rb') { |f| f.read }
      end
    end

    def self.mkcol_for_path(project, path)
      #Create directory
      pinfo = path.split("/")
      raise ForbiddenError unless pinfo.length == 2
      raise ForbiddenError unless pinfo[0] == "documents"
      container = project.documents.find_by_title(pinfo[1])
      if !container
        @doc = project.documents.build({ :title => pinfo[1],
          :description => 'Created from WEBDAV',
          :category_id => DocumentCategory.first.id})
        @doc.save
      end
    end

    def self.write_content_to_path(project, path, content)
      #Create a file
      pinfo = path.split("/")
      case pinfo.length
      when 2
        if pinfo[0] == "files"
          container = project
          file = project.attachments.find(:first, :conditions => [ "filename = ?", pinfo[1] ])
        end
      when 3
        if pinfo[0] == "files"
          container = project.versions.find_by_name(pinfo[1])
          file = container.attachments.find(:first, :conditions => [ "filename = ?", pinfo[2] ])
        end
        if pinfo[0] == "documents"
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
          a.save
        end
        uploaded_file.close!
      end
    end

    def move_to_path(dest_path, depth)
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

    def copy_to_path(dest_path, depth)
      raise ForbiddenError unless !@isdir
      self.class.do_file_action do
        self.class.write_content_to_path(@project, dest_path, filecontent)
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
  end
end
