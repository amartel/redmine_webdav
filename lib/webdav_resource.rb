# Copyright (c) 2006 Stuart Eccles
# Released under the MIT License.  See the LICENSE file for more details.

module Railsdav
  module Resource
    def status
      gen_status(200, "OK")
    end
      
    def displayname
      URI.escape(@displayname).gsub(/\+/, '%20') if @displayname
    end

    def href
      @href.gsub(/\+/, '%20') if @href
    end

    def gen_element(element_name, text = nil, attributes = {})
      element = REXML::Element.new(element_name)
      element.text = text if text
      attributes.each {|k, v| element.attributes[k] = v }
      element
    end

    def gen_status(status_code, reason_phrase)
      "HTTP/1.1 #{status_code} #{reason_phrase}"
    end
  end
end
