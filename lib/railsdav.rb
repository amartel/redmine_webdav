# WebDAV plugin - Copyright (c) 2010 Arnaud Martel
# Released under the GPL License.  See the LICENSE file for more details.
$:.unshift File.expand_path(File.dirname(__FILE__))

module Railsdav
  VERSION = '0.1.1'
end

require 'webdav_errors'
require 'webdav_resource'
require 'webdav_acts_as_webdav'
require 'webdav_file_resource'
require 'webdav_attachment_patch'