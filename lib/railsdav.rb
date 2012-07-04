# WebDAV plugin - Copyright (c) 2010 Arnaud Martel
# Released under the GPL License.  See the LICENSE file for more details.
$:.unshift File.expand_path(File.dirname(__FILE__))

module Railsdav
  VERSION = '0.1.1'
end

require 'webdav_errors'
require 'webdav_resource'
require 'acts_as_webdav'
require 'file_resource'
require 'attachment_patch'