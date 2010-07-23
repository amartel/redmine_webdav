# SCM Extensions plugin for Redmine
# Copyright (C) 2010 Arnaud MARTEL
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

module WebdavSubversionAdapterPatch
  def self.included(base) # :nodoc:
    base.send(:include, SubversionAdapterMethodsWebdav)

    base.class_eval do
      unloadable # Send unloadable so it will not be unloaded in development
    end

  end
end

module SubversionAdapterMethodsWebdav
  def webdav_gettmpdir(create = true)
    tmpdir = Dir.tmpdir
    t = Time.now.strftime("%Y%m%d")
    n = nil
    begin
      path = "#{tmpdir}/#{t}-#{$$}-#{rand(0x100000000).to_s(36)}"
      path << "-#{n}" if n
      Dir.mkdir(path, 0700)
      Dir.rmdir(path) unless create
    rescue Errno::EEXIST
      n ||= 0
      n += 1
      retry
    end

    if block_given?
      begin
        yield path
      ensure
        FileUtils.remove_entry_secure path if File.exist?(path)
        fname = "#{path}.txt"
        FileUtils.remove_entry_secure fname if File.exist?(fname)
      end
    else
      path
    end
  end

  def webdav_target(repository, path = '')
    base = repository.url
    base = base.sub(/^.*:\/\/[^\/]*\//,"file:///svnroot/")
    uri = "#{base}/#{path}"
    uri = URI.escape(URI.escape(uri), '[]')
    shell_quote(uri.gsub(/[?<>\*]/, ''))
  end

  def webdav_upload(project, path, content, comments, identifier)
    rev = identifier ? "@{identifier}" : ""
    folder_path = File.dirname(path)
    filename = File.basename(path)
    container =  entries(folder_path, identifier)
    if container
      error = false
      #use co +update + ci
      webdav_gettmpdir(false) do |dir|
        commentfile = "#{dir}.txt"
        File.open(commentfile, 'w') {|f|
          f.write(comments)
          f.flush
        }

        cmd = "#{Redmine::Scm::Adapters::SubversionAdapter::SVN_BIN} checkout #{webdav_target(project.repository, folder_path)}#{rev} #{dir} --depth empty --username #{User.current.login}"
        shellout(cmd)
        error = true if ($? != 0)

        entry = entries(path, identifier)
        if entry
          cmd = "#{Redmine::Scm::Adapters::SubversionAdapter::SVN_BIN} update #{File.join(dir, filename)} --username #{User.current.login}"
          shellout(cmd)
          error = true if ($? != 0)
        end

        File.open(File.join(dir, filename), "wb") do |f|
          f.write(content)
        end

        if !entry
          cmd = "#{Redmine::Scm::Adapters::SubversionAdapter::SVN_BIN} add #{File.join(dir, filename)} --username #{User.current.login}"
          shellout(cmd)
          error = true if ($? != 0)
        end
        if !error
          cmd = "#{Redmine::Scm::Adapters::SubversionAdapter::SVN_BIN} commit #{dir} -F #{commentfile} --username #{User.current.login}"
          shellout(cmd)
          error = true if ($? != 0 && $? != 256)
        end

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

  def webdav_delete(project, path, comments, identifier)
    return -1 if path.nil? || path.empty?
    rev = identifier ? "@{identifier}" : ""
    container =  entries(path, identifier)
    if container && path != "/"
      error = false
      webdav_gettmpdir(false) do |dir|
        commentfile = "#{dir}.txt"
        File.open(commentfile, 'w') {|f|
          f.write(comments)
          f.flush
        }
        cmd = "#{Redmine::Scm::Adapters::SubversionAdapter::SVN_BIN} delete #{webdav_target(project.repository, path)}#{rev}  -F #{commentfile} --username #{User.current.login}"
        shellout(cmd)
        error = true if ($? != 0 && $? != 256)
      end
      return error ? 1 : 0
    end
  end

  def webdav_mkdir(project, path, comments, identifier)
    return -1 if path.nil? || path.empty?
    rev = identifier ? "@{identifier}" : ""
    error = false
    webdav_gettmpdir(false) do |dir|
      commentfile = "#{dir}.txt"
      File.open(commentfile, 'w') {|f|
        f.write(comments)
        f.flush
      }
      cmd = "#{Redmine::Scm::Adapters::SubversionAdapter::SVN_BIN} mkdir #{webdav_target(project.repository, path)}#{rev} -F #{commentfile} --username #{User.current.login}"
      shellout(cmd)
      error = true if ($? != 0 && $? != 256)
    end
    return error ? 1 : 0
  end

  def webdav_move(project, path, dest_path, comments, identifier)
    return -1 if path.nil? || path.empty?
    rev = identifier ? "@{identifier}" : ""
    container =  entries(path, identifier)
    if container && path != "/"
      error = false
      webdav_gettmpdir(false) do |dir|
        commentfile = "#{dir}.txt"
        File.open(commentfile, 'w') {|f|
          f.write(comments)
          f.flush
        }
        cmd = "#{Redmine::Scm::Adapters::SubversionAdapter::SVN_BIN} move #{webdav_target(project.repository, path)}#{rev}  #{webdav_target(project.repository, dest_path)} -F #{commentfile} --username #{User.current.login}"
        shellout(cmd)
        error = true if ($? != 0 && $? != 256)
      end
      return error ? 1 : 0
    end
  end

  def webdav_copy(project, path, dest_path, comments, identifier)
    return -1 if path.nil? || path.empty?
    rev = identifier ? "@{identifier}" : ""
    container =  entries(path, identifier)
    if container && path != "/"
      error = false
      webdav_gettmpdir(false) do |dir|
        commentfile = "#{dir}.txt"
        File.open(commentfile, 'w') {|f|
          f.write(comments)
          f.flush
        }
        cmd = "#{Redmine::Scm::Adapters::SubversionAdapter::SVN_BIN} copy #{webdav_target(project.repository, path)}#{rev}  #{webdav_target(project.repository, dest_path)} -F #{commentfile} --username #{User.current.login}"
        shellout(cmd)
        error = true if ($? != 0 && $? != 256)
      end
      return error ? 1 : 0
    end
  end
end

Redmine::Scm::Adapters::SubversionAdapter.send(:include, WebdavSubversionAdapterPatch)
