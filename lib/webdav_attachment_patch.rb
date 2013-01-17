# WebDAV plugin - Copyright (c) 2010 Arnaud Martel
# Released under the GPL License.  See the LICENSE file for more details.
require_dependency 'attachment'

module WebDavAttachmentPatch
  def self.included(base) # :nodoc:
    base.extend(WebDavClassMethods)

    base.send(:include, WebDavInstanceMethods)

    # Same as typing in the class
    base.class_eval do
      unloadable # Send unloadable so it will not be unloaded in development
      alias_method_chain(:files_to_final_location, :webdav) 
      class << self
        # I dislike alias method chain, it's not the most readable backtraces

      end

    end

  end

  module WebDavClassMethods

  end

  module WebDavInstanceMethods
    #no change except @temp_file.size >= 0 and self.filename = sanitize_webdavfilename(@temp_file.original_filename)
    def webdavfile=(incoming_file)
      unless incoming_file.nil?
        @temp_file = incoming_file
        if @temp_file.size >= 0
          if @temp_file.respond_to?(:original_filename)
            self.filename = sanitize_webdavfilename(@temp_file.original_filename)
            self.filename.force_encoding("UTF-8") if filename.respond_to?(:force_encoding)
          end
          if @temp_file.respond_to?(:content_type)
            self.content_type = @temp_file.content_type.to_s.chomp
          end
          if content_type.blank? && filename.present?
            self.content_type = Redmine::MimeType.of(filename)
          end
          self.filesize = @temp_file.size
        end
      end
    end

    def webdavfile
      nil
    end

    #no change except @temp_file.size >= 0 and remove logger call
    def files_to_final_location_with_webdav
      if @temp_file && (@temp_file.size >= 0)
        md5 = Digest::MD5.new
        File.open(diskfile, "wb") do |f| 
          if @temp_file.respond_to?(:read)
            buffer = ""
            while (buffer = @temp_file.read(8192))
              f.write(buffer)
              md5.update(buffer)
            end
          else
            f.write(@temp_file)
            md5.update(@temp_file)
          end
        end
        self.digest = md5.hexdigest
      end
      @temp_file = nil
      # Don't save the content type if it's longer than the authorized length
      if self.content_type && self.content_type.length > 255
        self.content_type = nil
      end
    end

    private

    #like sanitize_filename but don't replace invalid characters with underscore
    def sanitize_webdavfilename(value)
      # get only the filename, not the whole path
      just_filename = value.gsub(/^.*(\\|\/)/, '')
      # NOTE: File.basename doesn't work right with Windows paths on Unix
      # INCORRECT: just_filename = File.basename(value.gsub('\\\\', '/'))

      # Finally, replace all non alphanumeric, hyphens or periods with underscore
      @filename = just_filename
    end

  end
end

# Add module to Issue
Attachment.send(:include, WebDavAttachmentPatch)
