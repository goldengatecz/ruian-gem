require 'nokogiri'
require 'ruian/cuzk_http'
require 'time'

class Ruian
  class InspireAddresses
    class Error < StandardError; end

    BASE = 'https://services.cuzk.gov.cz/wfs/inspire-ad-wfs.asp'
    NS = {
      'wfs' => 'http://www.opengis.net/wfs/2.0', 'ad' => 'http://inspire.ec.europa.eu/schemas/ad/4.0',
      'gml' => 'http://www.opengis.net/gml/3.2', 'xlink' => 'http://www.w3.org/1999/xlink'
    }.freeze
    CRS = 'http://www.opengis.net/def/crs/EPSG/0/5514'
    BATCH_SIZE = 100

    def initialize(http: CuzkHttp.new(%w[services.cuzk.gov.cz services.cuzk.cz]))
      @http = http
    end

    def each_address(codes)
      codes.each_slice(BATCH_SIZE) do |batch|
        params = { service: 'WFS', version: '2.0.0', request: 'GetFeature', typenames: 'ad:Address',
                   resourceId: batch.map { |code| "AD.#{Integer(code)}" }.join(',') }
        body = +''
        @http.get("#{BASE}?#{URI.encode_www_form(params)}", max_bytes: 2 * 1024**2) { |chunk| body << chunk }
        doc = Nokogiri::XML(body) { |config| config.strict.nonet }
        features = doc.xpath('/wfs:FeatureCollection/wfs:member/ad:Address', NS).map { |node| address(node) }
        returned = features.map { |item| item.fetch(:code) }
        unless returned.sort == batch.sort
          raise Error, "ČÚZK WFS returned different addresses, missing #{(batch - returned).first(10).join(', ')}"
        end
        features.each { |feature| yield feature }
      end
    end

    private

    def address(node)
      code = numeric_id(node.at_xpath('./@gml:id', NS)&.value, /\AAD\.(\d+)\z/)
      parts = components(node)
      numbers = designators(node)
      house_type = numbers.fetch('buildingIdentifierPrefix')
      raise Error, "Unknown RUIAN house number type #{house_type.inspect}" unless %w[č.p. č.ev.].include?(house_type)

      house_number = Integer(numbers.fetch('buildingIdentifier'), 10)
      orientation = numbers['addressNumber'].to_s + numbers['addressNumberExtension'].to_s
      city_code, city_name = parts.fetch(:city)
      part_code, part_name = parts.fetch(:part, [nil, nil])
      valid_from = node.at_xpath('./ad:validFrom', NS)&.text
      {
        code: code, city_code: city_code, city_name: city_name, part_code: part_code, part_name: part_name,
        street_name: parts.dig(:street, 1), mop_name: parts.dig(:mop, 1), momc_name: parts.dig(:momc, 1),
        zip: parts.fetch(:zip).first.to_s, house_number: house_number, house_type: house_type,
        orientation: orientation.empty? ? nil : orientation, point: point(node),
        valid_from: (Time.iso8601(valid_from) unless valid_from.to_s.empty?)
      }
    end

    def components(node)
      node.xpath('./ad:component', NS).each_with_object({}) do |component, result|
        uri = URI(component.at_xpath('./@xlink:href', NS).value)
        id = URI.decode_www_form(uri.query.to_s).to_h['Id']
        # WFS may emit either a full reference URL or a plain feature ID.
        id ||= uri.path if uri.relative?
        name = component.at_xpath('./@xlink:title', NS)&.value
        case id
        when /\AAU\.4\.(\d+)\z/ then result[:city] = [Integer(Regexp.last_match(1), 10), name]
        when /\AAA\.(\d+)\z/ then result[:part] = [Integer(Regexp.last_match(1), 10), name]
        when /\AAA\.MOMC\.(\d+)\z/ then result[:momc] = [Integer(Regexp.last_match(1), 10), name]
        when /\AAA\.MOP\.(\d+)\z/ then result[:mop] = [Integer(Regexp.last_match(1), 10), name]
        when /\ATF\.(\d+)\z/ then result[:street] = [Integer(Regexp.last_match(1), 10), name]
        when /\APD\.(\d{5})\z/ then result[:zip] = [Regexp.last_match(1), name]
        end
      end
    end

    def designators(node)
      node.xpath('.//ad:LocatorDesignator', NS).to_h do |designator|
        type = designator.at_xpath('./ad:type/@xlink:href', NS)&.value.to_s.split('/').last
        [type, designator.at_xpath('./ad:designator', NS)&.text]
      end
    end

    def point(node)
      geometry = node.at_xpath("./ad:position/ad:GeographicPosition[ad:default='true']/ad:geometry/gml:Point", NS)
      return unless geometry

      raise Error, "Unexpected ČÚZK coordinate reference system #{geometry['srsName']}" unless geometry['srsName'] == CRS

      point = geometry.at_xpath('./gml:pos', NS).text.split.map { |value| Float(value) }
      raise Error, 'Expected two ČÚZK coordinates' unless point.size == 2

      point
    end

    def numeric_id(value, pattern)
      match = pattern.match(value.to_s)
      raise Error, "Unexpected ČÚZK feature identifier #{value.inspect}" unless match

      Integer(match[1], 10)
    end
  end
end
