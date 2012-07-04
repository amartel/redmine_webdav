# WebDAV plugin - Copyright (c) 2010 Arnaud Martel
# Released under the GPL License.  See the LICENSE file for more details.

module WebdavFilesystemAdapterPatch
  def self.included(base) # :nodoc:
    base.send(:include, FilesystemAdapterMethodsWebdav)

    base.class_eval do
      unloadable # Send unloadable so it will not be unloaded in development
    end

  end
end

module FilesystemAdapterMethodsWebdav
  def webdav_upload(repository, path, content, comments, identifier)
    return -1 if webdav_invalid_path(path)
    metapath = (repository.url =~ /\/files$/  && File.exist?(repository.url.sub(/\/files/, "/attributes")))
    folder_path = File.dirname(path)
    filename = File.basename(path)
    container =  entries(folder_path, identifier)
    if container
      error = false

      begin
  
        if (!(File.basename(path) =~ /^\./ ) && repository.supports_all_revisions?)
          rev = -1
          rev = repository.latest_changeset.revision.to_i if repository.latest_changeset
          rev = rev + 1
          action = "A"
          action = "M" if File.exists?(File.join(repository.url, folder_path, filename)) 
          changeset = Changeset.create(:repository => repository,
                                                     :revision => rev, 
                                                     :committer => User.current.login, 
                                                     :committed_on => Time.now,
                                                     :comments => comments)
          Change.create( :changeset => changeset, :action => action, :path => File.join("/", folder_path, filename))
        end
                                                   
        File.open(File.join(repository.url, folder_path, filename), "wb") do |f|
          f.write(content)
        end
        if metapath
          metapathtarget = File.join(repository.url, folder_path, filename).sub(/\/files\//, "/attributes/")
          FileUtils.mkdir_p File.dirname(metapathtarget)
          File.open(metapathtarget, "w") do |f|
            f.write("#{User.current}\n")
            f.write("#{rev}\n")
          end
        end
      rescue
        error = true
      end

      if error
        return 1
      else
        return 0
      end
    else
      return 2
    end
  end

  def webdav_delete(repository, path, comments, identifier)
    return -1 if path.nil? || path.empty?
    return -1 if webdav_invalid_path(path)
    metapath = (repository.url =~ /\/files$/  && File.exist?(repository.url.sub(/\/files/, "/attributes")))
    fullpath = File.join(repository.url, path)
    if File.exist?(fullpath) && path != "/"
      error = false

      begin
        if (!(File.basename(path) =~ /^\./ ) && repository.supports_all_revisions?)
          rev = -1
          rev = repository.latest_changeset.revision.to_i if repository.latest_changeset
          rev = rev + 1
          changeset = Changeset.create(:repository => repository,
                                                     :revision => rev, 
                                                     :committer => User.current.login, 
                                                     :committed_on => Time.now,
                                                     :comments => comments)
          Change.create( :changeset => changeset, :action => 'D', :path => File.join("/", path))
        end
                                                   
        if File.directory?(fullpath)
          FileUtils.remove_entry_secure fullpath
        else
          File.delete(fullpath)
        end
        if metapath
          metapathtarget = fullpath.sub(/\/files\//, "/attributes/")
          FileUtils.remove_entry_secure metapathtarget if File.exist?(metapathtarget)
        end
      rescue
        error = true
      end

      return error ? 1 : 0
    end
  end

  def webdav_mkdir(repository, path, comments, identifier)
    return -1 if path.nil? || path.empty?
    return -1 if webdav_invalid_path(path)
    metapath = (repository.url =~ /\/files$/  && File.exist?(repository.url.sub(/\/files/, "/attributes")))
    fullpath = File.join(repository.url, path)
    error = false
    begin
      if (!(File.basename(path) =~ /^\./ ) && repository.supports_all_revisions?)
        rev = -1
        rev = repository.latest_changeset.revision.to_i if repository.latest_changeset
        rev = rev + 1
        changeset = Changeset.create(:repository => repository,
                                                   :revision => rev, 
                                                   :committer => User.current.login, 
                                                   :committed_on => Time.now,
                                                   :comments => comments)
        Change.create( :changeset => changeset, :action => 'A', :path => File.join("/", path))
      end
      Dir.mkdir(File.join(repository.url, path))
      if metapath
        metapathtarget = fullpath.sub(/\/files\//, "/attributes/")
        Dir.mkdir(metapathtarget)
      end
    rescue
      error = true
    end

    return error ? 1 : 0
  end

  def webdav_move(repository, path, dest_path, comments, identifier)
    return -1 if path.nil? || path.empty? || dest_path.nil? || dest_path.empty?
    return -1 if webdav_invalid_path(path)
    return -1 if webdav_invalid_path(dest_path)
    metapath = (repository.url =~ /\/files$/  && File.exist?(repository.url.sub(/\/files/, "/attributes")))
    fullpath = File.join(repository.url, path)
    if File.exist?(fullpath) && path != "/"
      error = false
      begin
        if (!(File.basename(path) =~ /^\./ ) && repository.supports_all_revisions?)
          rev = -1
          rev = repository.latest_changeset.revision.to_i if repository.latest_changeset
          rev = rev + 1
          changeset = Changeset.create(:repository => repository,
                                                     :revision => rev, 
                                                     :committer => User.current.login, 
                                                     :committed_on => Time.now,
                                                     :comments => comments)
          Change.create( :changeset => changeset, :action => 'R', :path => File.join("/", dest_path), :from_path => File.join("/", path))
        end
        
        FileUtils.move fullpath, File.join(repository.url, dest_path)
        if metapath
          metapathfull = fullpath.sub(/\/files\//, "/attributes/")
          metapathtarget = File.join(repository.url, dest_path).sub(/\/files\//, "/attributes/")
          FileUtils.move metapathfull, metapathtarget if File.exist?(metapathfull)
        end
      rescue
        error = true
      end
      return error ? 1 : 0
    end
  end

  def webdav_copy(repository, path, dest_path, comments, identifier)
    return -1 if path.nil? || path.empty? || dest_path.nil? || dest_path.empty?
    return -1 if webdav_invalid_path(path)
    return -1 if webdav_invalid_path(dest_path)
    metapath = (repository.url =~ /\/files$/  && File.exist?(repository.url.sub(/\/files/, "/attributes")))
    rev = identifier ? "@{identifier}" : ""
    fullpath = File.join(repository.url, path)
    if File.exist?(fullpath) && path != "/"
      error = false
      begin
        if (!(File.basename(path) =~ /^\./ ) && repository.supports_all_revisions?)
          rev = -1
          rev = repository.latest_changeset.revision.to_i if repository.latest_changeset
          rev = rev + 1
          changeset = Changeset.create(:repository => repository,
                                                     :revision => rev, 
                                                     :committer => User.current.login, 
                                                     :committed_on => Time.now,
                                                     :comments => comments)
          Change.create( :changeset => changeset, :action => 'R', :path => File.join("/", dest_path), :from_path => File.join("/", path))
        end
        
        FileUtils.cp_r fullpath, File.join(repository.url, dest_path)
        if metapath
          metapathfull = fullpath.sub(/\/files\//, "/attributes/")
          metapathtarget = File.join(repository.url, dest_path).sub(/\/files\//, "/attributes/")
          FileUtils.cp_r metapathfull, metapathtarget if File.exist?(metapathfull)
        end
      rescue
        error = true
      end
      return error ? 1 : 0
    end

  end

  def webdav_invalid_path(path)
    return path =~ /\/\.\.\//
  end
end

Redmine::Scm::Adapters::FilesystemAdapter.send(:include, WebdavFilesystemAdapterPatch)
