require_dependency 'attachment'

# Patches Redmine's Issues dynamically. Adds a relationship
# Issue +belongs_to+ to Deliverable
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
    # Wraps the association to get the Deliverable subject. Needed for the
    # Query and filtering
    def webdavfile=(incoming_file)
      unless incoming_file.nil?
        @temp_file = incoming_file
        if @temp_file.size >= 0
          self.filename = sanitize_webdavfilename(@temp_file.original_filename)
          self.disk_filename = Attachment.disk_filename(filename)
          self.content_type = @temp_file.content_type.to_s.chomp
          if content_type.blank?
            self.content_type = Redmine::MimeType.of(filename)
          end
          self.filesize = @temp_file.size
        end
      end
    end

    #no change except @temp_file.size >= 0
    def files_to_final_location_with_webdav
      if @temp_file && (@temp_file.size >= 0)
        logger.debug("saving '#{self.diskfile}'")
        md5 = Digest::MD5.new
        File.open(diskfile, "wb") do |f| 
          buffer = ""
          while (buffer = @temp_file.read(8192))
            f.write(buffer)
            md5.update(buffer)
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
