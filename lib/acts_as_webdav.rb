# Copyright (c) 2006 Stuart Eccles
# Released under the MIT License.  See the LICENSE file for more details.
#
# Modified by Marcello Nuccio.
#
# Here is an example configuration:
#
# A model:
#
#   class WebdavResource < Railsdav::FileResource
#   end
#
# A controller:
#
#   class WebDavController < ApplicationController
#     skip_before_filter :verify_authenticity_token
#     acts_as_webdav
#   end
#
# the controller must then have a route like:
#
#   ActionController::Routing::Routes.draw do |map|
#     map.connect 'home/*path_info', :controller  => 'web_dav', :action => 'webdav'
#     map.root :controller  => 'web_dav', :action => 'webdav'
#   end
#
# and you should add webdav methods into config/environments.rb:
#
#   ActionController::ACCEPTED_HTTP_METHODS.merge(%w{propfind mkcol move copy})
#
#
# Add authentication using rails authenticate_with_http_basic method.
#

require 'action_controller'
require 'unicode'
require 'uuid'

module Railsdav
  module Acts #:nodoc:
    module Webdav #:nodoc:

      ACTIONS = %w(lock unlock options propfind proppatch mkcol delete put copy move)
      VERSIONS = %w(1 2)
      module ActMethods
        def acts_as_webdav(options = {})
          class_attribute :dav_actions
          class_attribute :dav_versions
          class_attribute :resource_model

          self.resource_model = options[:resource_model]
          options[:extra_actions]      ||= []
          options[:extra_dav_versions] ||= []
          self.dav_actions = ACTIONS + options[:extra_actions]
          self.dav_versions = VERSIONS + options[:extra_dav_versions]

          include InstanceMethods unless included_modules.include?(InstanceMethods)
        end
      end

      module InstanceMethods
        def webdav
          if @project.nil?
            webdavnf
          end
          method = "webdav_#{request.head? ? "head" : request.method_symbol.to_s}"
          begin
            raise NotImplementedError unless respond_to?(method, true)
            set_depth
            set_path_info
            #            if @path_info.split("/").last[0,1] != "."
            check_read(@path_info)
            __send__(method)
            #            else
            #              render :nothing => true, :status => 404
            #            end
          rescue BaseError => error
            render :nothing => true, :status => error.http_status
          end
        end

        def rootwebdav
          set_depth
          if request.method_symbol == :options
            webdav_options
          else
            begin
              raise NotImplementedError unless (request.method_symbol == :propfind || request.method_symbol == :options)
              #resources = Project.find(:all, :conditions => Project.visible_condition(User.current))
              resources = []
              ms = User.current.memberships
              ms.each do |m|
                resources << m.project
              end
              href = url_for(:only_path => true, :path_info => params[:path_info])
              first = resources.first

              $KCODE = 'UTF8'
              #Rails.logger.error "dans rootwebdav"          
              xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?> <D:multistatus xmlns:D=\"DAV:\">"
              xml << "<D:response>"
              xml << "<D:href>#{href}</D:href>"
              xml << "<D:propstat><D:prop>"
              xml << "<D:displayname>webdav</D:displayname>"
              xml << "<D:creationdate>#{first.created_on.xmlschema}</D:creationdate>"
              xml << "<D:getlastmodified>#{first.updated_on.httpdate}</D:getlastmodified>"
              xml << "<D:getetag>1-0-#{first.created_on.to_i}</D:getetag>"
              xml << "<D:getcontenttype>httpd/unix-directory</D:getcontenttype>"
              xml << "<D:getcontentlength>0</D:getcontentlength>"
              #:displayname, :creationdate, :getlastmodified,:getetag, :getcontenttype, :getcontentlength
              xml << "<D:resourcetype>"
              xml << "<D:collection/>"
              xml << "</D:resourcetype>"
              xml << "</D:prop>"
              xml << "<D:status>HTTP/1.1 200 OK</D:status>"
              xml << "</D:propstat>"
              xml << "</D:response>"

              if @depth > 0
                resources.each do |project|
                  if @user.allowed_to?(:webdav_access, project)
                    xml << "<D:response>"
                    xml << "<D:href>" << File.join(href, URI.escape(project.identifier)) << "</D:href>"
                    xml << "<D:propstat><D:prop>"
                    xml << "<D:displayname>#{project.identifier}</D:displayname>"
                    xml << "<D:creationdate>#{project.created_on.xmlschema}</D:creationdate>"
                    xml << "<D:getlastmodified>#{project.updated_on.httpdate}</D:getlastmodified>"
                    xml << "<D:getetag>1-0-#{project.created_on.to_i}</D:getetag>"
                    xml << "<D:getcontenttype>httpd/unix-directory</D:getcontenttype>"
                    xml << "<D:getcontentlength>0</D:getcontentlength>"
                    xml << "<D:resourcetype>"
                    xml << "<D:collection/>"
                    xml << "</D:resourcetype>"
                    xml << "</D:prop>"
                    xml << "<D:status>HTTP/1.1 200 OK</D:status>"
                    xml << "</D:propstat>"
                    xml << "</D:response>"
                  end
                end
              end
              xml << "</D:multistatus>"

              render :text => xml, :status => 207, :layout => false, :content_type => "application/xml"
            rescue BaseError => error
              render :nothing => true, :status => error.http_status
            end
          end
        end

        def webdavnf
          Rails.logger.error "project: #{@project}"
          if request.method_symbol == :options
            webdav_options
          else
            render :nothing => true, :status => 404
          end
        end

        private

        def webdav_options
          response.headers['DAV'] = dav_versions.join(",")
          response.headers['MS-Author-Via'] = "DAV"
          response.headers["Allow"] = dav_actions.map(&:upcase).join(",")
          render :nothing => true, :status => 200
        end

        def out_of_date
          state=false
          @lock=Lock.find(:first, :conditions => ["resource = ?", request.url] )
          if not @lock.nil?
            current=Time.now - 36000
            logger.debug "DEBUG: lock timestamp: #{@lock[:timestamp].inspect} and current: #{current}"
            if @lock[:timestamp] < current
              logger.debug "DEBUG: Lock for #{request.url} out of date"
              state=true
              Lock.delete_all( :resource=> request.url )
            end
          end
          state
        end

        def webdav_lock
          resource = find_resource_by_path(@path_info)
          raise NotFoundError unless resource

          locktype = "read"
          lockscope = "exclusive"
          owner = ""
          if params[:lockinfo]
            locktype = params[:lockinfo][:locktype] ? params[:lockinfo][:locktype].keys.first : "read"
            lockscope = params[:lockinfo][:lockscope] ? params[:lockinfo][:lockscope].keys.first : "exclusive"
            owner = User.current.login
          end

          newlock=UUID.create.guid
          s = out_of_date
          if !@lock.nil? and not s
            if @lock[:owner] == User.current.login
              newlock = @lock[:uid]
              Lock.delete_all( :resource=> request.url )
            else
              render :status => 423, :nothing => true
            end
          end

          mylock=Lock.create ( :uid=>newlock, :locktype=>locktype, :lockscope=>lockscope, :owner=>User.current.login,
          :resource => request.url, :timestamp=> Time.now )

          xml = "<?xml version=\"1.0\" encoding=\"utf-8\" ?>"
          xml << "<D:prop xmlns:D=\"DAV:\">"
          xml << "<D:lockdiscovery>"
          xml << "<D:activelock>"
          xml << "<D:locktype><D:#{locktype}/></D:locktype>"
          xml << "<D:lockscope><D:#{lockscope}/></D:lockscope>"
          xml << "<D:depth>#{request.headers["Depth"]}</D:depth>"
          xml << "<D:owner>#{owner}</D:owner>"
          xml << "<D:timeout>Second-36000</D:timeout>"
          xml << "<D:locktoken><D:href>urn:uuid:#{newlock}</D:href></D:locktoken>"
          xml << "<D:lockroot><D:href>#{request.url}</D:href></D:lockroot>"
          xml << "</D:activelock>"
          xml << "</D:lockdiscovery>"
          xml << "</D:prop>"

          logger.debug "DEBUG: lock create error: " + mylock.errors.full_messages.inspect
          response.headers["Lock-Token"] = "<urn:uuid:"+ newlock + ">"
          render :text => xml, :status => 200, :layout => false, :content_type => "application/xml"
        end

        def webdav_unlock
          #TODO implementation for now return a 200 OK
          resource = find_resource_by_path(@path_info)
          raise NotFoundError unless resource
          logger.debug "DEBUG: lock_tocken: " + request.headers["Lock-Token"].split(':')[2].chop.inspect
          tocken=request.headers["Lock-Token"].split(':')[2].chop
          Lock.delete_all( :uid=> tocken )
          render :nothing => true, :status => 200
        end

        PROPFIND_TEMPLATE = File.dirname(__FILE__) + '/../templates/propfind.xml.builder'

        def webdav_propfind
          resource = find_resource_by_path(@path_info)
          raise NotFoundError unless resource
          resources = get_dav_resource_props(resource)

          $KCODE = 'UTF8'
          #RAILS_DEFAULT_LOGGER.info "Dans propfind"
          xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?> <D:multistatus xmlns:D=\"DAV:\">"
          resources.flatten.each do |res|
            xml << "<D:response>"
            xml << "<D:href>" << res.href << "</D:href>"
            xml << "<D:propstat><D:prop>"
            res.properties.each do |property, value|
              if !value
                value = ""
              end
              xml << "<D:#{property}>#{value}</D:#{property}>"
            end
            xml << "<D:resourcetype>"
            xml << "<D:collection/>" if res.collection?
            xml << "</D:resourcetype>"
            xml << "</D:prop>"
            xml << "<D:status>HTTP/1.1 200 OK</D:status>"
            xml << "</D:propstat>"
            xml << "</D:response>"
          end
          xml << "</D:multistatus>"
          render :text => xml, :status => 207, :layout => false, :content_type => "application/xml"

          #render(:file => PROPFIND_TEMPLATE, :status => 207, :locals => { :resources => resources.flatten } )
        end

        PROPPATCH_TEMPLATE = File.dirname(__FILE__) + '/../templates/proppatch.xml.builder'

        def webdav_proppatch
          resource = find_resource_by_path(@path_info)
          raise NotFoundError unless resource

          begin
            req_xml = REXML::Document.new request.raw_post
          rescue REXML::ParseException
            raise BadRequestBodyError
          end
          ns = { "" => "DAV:" }
          remove_properties = REXML::XPath.match(req_xml, "/propertyupdate/remove/prop/*", ns)
          set_properties = REXML::XPath.match(req_xml, "/propertyupdate/set/prop/*", ns)

          render(:file => PROPPATCH_TEMPLATE, :status => 207,
          :locals => { :resource => resource,
            :remove_properties => remove_properties,
            :set_properties => set_properties })
        end

        def webdav_mkcol
          check_write(@path_info)
          mkcol_for_path(@path_info)
          render :nothing => true, :status => 201
        end

        def webdav_delete
          if Lock.exists?( :resource=>request.url )
            if not Lock.exists?( :resource=>request.url, :owner=>User.current.login )
              raise ForbiddenError
            end
          end
          check_write(@path_info)
          resource = find_resource_by_path(@path_info)
          if resource
            resource.delete!
          end

          render :nothing => true, :status => 204
        end

        def webdav_put
          if Lock.exists?( :resource=>request.url )
            if not Lock.exists?( :resource=>request.url, :owner=>User.current.login )
              raise ForbiddenError
            end
          end

          check_write(@path_info)
          write_content_to_path(@path_info, request.raw_post)
          render :nothing => true, :status => 201
        end

        def with_source_and_destination_resources
          begin
            uri = URI.parse(request.env['HTTP_DESTINATION'].chomp('/'))
            base_path = url_for(:only_path => true, :path_info => "")
            raise ForbiddenError if uri.path !~  /^#{Regexp.escape(base_path)}\//
            logger.debug "destination_path = #{$'.inspect}"
            dest_path = $'
            dest_path = convert_path_in(dest_path)
          rescue URI::InvalidURIError
            raise BadGatewayError
          end

          source_resource = find_resource_by_path(@path_info)
          raise NotFoundError unless source_resource
          dest_resource = find_resource_by_path(dest_path)
          raise PreconditionFailsError if dest_resource && !overwrite_destination?

          yield(source_resource, dest_path)
          render :nothing => true, :status => (dest_resource ? 204 : 201)
          #render :nothing => true, :status => 201
        end

        def webdav_copy
          with_source_and_destination_resources do |source_resource, dest_path|
            check_write(dest_path)
            copy_to_path(source_resource, dest_path, @depth)
          end
        end

        def webdav_move
          if Lock.exists?( :resource=>request.url )
            if not Lock.exists?( :resource=>request.url, :owner=>User.current.login )
              raise ForbiddenError
            end
          end
          with_source_and_destination_resources do |source_resource, dest_path|
            check_write(dest_path)
            move_to_path(source_resource, dest_path, @depth)
          end
        end

        def webdav_get
          resource = find_resource_by_path(@path_info)
          raise NotFoundError unless resource
          data_to_send = resource.data
          #          raise NotFoundError if data_to_send.blank?

          if request.headers["If-Modified-Since"]
            if (Time.httpdate(request.headers["If-Modified-Since"].split(';').first) - Time.httpdate(resource.getlastmodified)) >= -0.1
              render :nothing => true, :status => 304
              return
            end
          end
          response.headers["Last-Modified"] = resource.getlastmodified
          if data_to_send.kind_of?(File)
            send_file File.expand_path(data_to_send.path), :filename => resource.displayname, :stream => true
          else
            send_data data_to_send, :filename => resource.displayname
          end
        end

        def webdav_head
          resource = find_resource_by_path(@path_info)
          raise NotFoundError if resource.blank?
          response.headers["Last-Modified"] = resource.getlastmodified
          render :nothing => true, :status => 200
        end

        private

        #
        # These are default implementations
        # If you do not want to implement one of them, dont put
        # the corresponding HTTP method in ACCEPTED_HTTP_METHODS
        #

        def mkcol_for_path(path)
          raise ForbiddenError unless resource_model
          resource_model.mkcol_for_path(@project, path)
        end

        def move_to_path(resource, dest_path, depth)
          raise ForbiddenError unless resource_model
          resource.move_to_path(dest_path, depth)
        end

        def write_content_to_path(path, content)
          raise ForbiddenError unless resource_model
          resource_model.write_content_to_path(@project, path, content)
        end

        def copy_to_path(resource, dest_path, depth)
          raise ForbiddenError unless resource_model
          resource.copy_to_path(dest_path, depth)
        end

        def find_resource_by_path(path)
          raise ForbiddenError unless resource_model
          href = url_for(:only_path => true, :path_info => params[:path_info])
          resource_model.initialize_by_path_and_href(@project, path, href)
        end

        def overwrite_destination?
          request.env['HTTP_OVERWRITE'] == 'T'
        end

        def get_dav_resource_props(resource)
          @depth -= 1
          ret_set = [ resource ]

          ret_set += (resource.children.map do |child|
            get_dav_resource_props(child)
          end) if @depth >= 0 && resource.children

          ret_set
        end

        def convert_path_in(path)
          case request.env["HTTP_USER_AGENT"]
          when /cadaver/
            URI.unescape(URI.unescape(path))
          else
            URI.unescape(path)
          end
        end

        def set_path_info
          path = params[:path_info].split('/').drop(1).join('/')
          @path_info = convert_path_in(path)
        end

        def set_depth
          depth_header = request.env['HTTP_DEPTH']
          @depth = depth_header == 'infinity' ? 50 : (Integer(depth_header || 1) rescue 1)
        end

        def check_read(path)
          setting = WebdavSetting.find_or_create @project.id
          if (setting.subversion_only && setting.subversion_enabled)
            raise ForbiddenError unless @user.allowed_to?(:browse_repository, @project)
          else
            @pinfo = path.split("/")
            if @pinfo.length > 0
              case @pinfo[0]
              when setting.files_label
                raise ForbiddenError unless (setting.files_enabled && @user.allowed_to?(:view_files, @project))
              when setting.documents_label
                raise ForbiddenError unless (setting.documents_enabled && @user.allowed_to?(:view_documents, @project))
              when setting.subversion_label
                raise ForbiddenError unless (setting.subversion_enabled && @user.allowed_to?(:browse_repository, @project))
              end
            end
          end
        end

        def check_write(path)
          setting = WebdavSetting.find_or_create @project.id
          if request.env["HTTP_USER_AGENT"] =~ /Darwin/
            raise ForbiddenError unless setting.macosx_write
          end
          if (setting.subversion_only && setting.subversion_enabled)
            raise ForbiddenError unless (@user.allowed_to?(:commit_access, @project) && @project.repository.scm.respond_to?('webdav_upload'))
          else
            @pinfo = path.split("/")
            if @pinfo.length > 0
              case @pinfo[0]
              when setting.files_label
                raise ForbiddenError unless (setting.files_enabled && @user.allowed_to?(:manage_files, @project))
              when setting.documents_label
                raise ForbiddenError unless (setting.documents_enabled && @user.allowed_to?(:manage_documents, @project))
              when setting.subversion_label
                raise ForbiddenError unless (setting.subversion_enabled && @user.allowed_to?(:commit_access, @project) && @project.repository.scm.respond_to?('webdav_upload'))
              end
            else
              raise ForbiddenError
            end
          end

        end
      end
    end
  end
end
