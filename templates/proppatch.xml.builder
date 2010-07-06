xml.D(:multistatus, "xmlns:D" => "DAV:") do
  xml.D :response do
    xml.D :href, URI.escape(resource.href)

    remove_properties.each do |remove_property|
      xml.D :propstat do
        xml.D :prop do
          xml.tag! remove_property.name.to_sym, remove_property.attributes
        end
        sym = "remove_#{remove_property.name}".to_sym
        if resource.respond_to?(sym)
          xml.D(:status, resource.__send__(sym))
        else
          xml.D :status, "HTTP/1.1 200 OK"
        end
      end
    end

    set_properties.each do |set_property|
      xml.D :propstat do
        xml.D :prop do
          xml.D set_property.name.to_sym, set_property.attributes
        end
        sym = "set_#{set_property.name}".to_sym
        if resource.respond_to?(sym)
          method = resource.method(sym)
          if method.arity == 1 && set_property.children && !set_property.children.empty?
            xml.D :status, method.call(set_property.children.first.to_s)
          else
            xml.D :status, method.call
          end
        else
          xml.D :status, "HTTP/1.1 200 OK"
        end
      end
    end
    xml.D :responsedescription
  end
end
