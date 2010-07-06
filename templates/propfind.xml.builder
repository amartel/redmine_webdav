xml.instruct!
xml.D(:multistatus, "xmlns:D" => "DAV:") do
  resources.each do |resource|
    xml.D :response do
      xml.D :href, resource.href
      xml.D :propstat do
        xml.D :prop do
          resource.properties.each do |property, value|
            xml.D(property, value)
          end
          xml.D :resourcetype do
            xml.D :collection if resource.collection?
          end
        end
        xml.D :status, resource.status
      end
    end
  end
end
