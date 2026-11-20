require 'date'
require 'nokogiri'
require 'tempfile'
require 'zip'
require 'ruian/cuzk_http'

class Ruian
  class VfrChanges
    class Error < StandardError; end

    STANDARD = 'ST_ZZSZ'
    ADDRESSES = 'ST_ZADS'
    SERIES = { STANDARD => 'soucasna', ADDRESSES => 'specialni' }.freeze
    NAMESPACES = {
      STANDARD => 'urn:cz:isvs:ruian:schemas:VymennyFormatTypy:v1',
      ADDRESSES => 'urn:cz:isvs:ruian:schemas:VymennyFormatAdresTypy:v1'
    }.freeze
    MAX_DAYS = 62
    MAX_XML_BYTES = 256 * 1024**2
    Record = Struct.new(:type, :code, :attributes)
    Release = Struct.new(:name, :previous, :records)

    def initialize(http: CuzkHttp.new)
      @http = http
    end

    def each_release(series, snapshot_on:, previous:, through:)
      check_series!(series)
      start = previous ? release_date(previous, series) : snapshot_on
      raise Error, "RUIAN #{series} cursor predates the snapshot" if start < snapshot_on
      raise Error, "RUIAN #{series} backlog exceeds #{MAX_DAYS} days" if (through - start) > MAX_DAYS

      (start.next_day..through).each do |date|
        release = fetch(series, date)
        next unless release

        predecessor = release_date(release.previous, series)
        unless predecessor < date && (previous ? release.previous == previous : predecessor <= snapshot_on)
          raise Error, "Gap in RUIAN #{series}: #{release.name} follows #{release.previous}, cursor #{previous || snapshot_on}"
        end
        yield release
        previous = release.name
      end
      previous
    end

    def fetch(series, date)
      check_series!(series)
      name = "#{date.strftime('%Y%m%d')}_#{series}.xml"
      url = "https://vdp.cuzk.gov.cz/vymenny_format/#{SERIES.fetch(series)}/#{name}.zip"
      Tempfile.create(['ruian-vfr-', '.zip'], binmode: true) do |archive|
        return unless @http.get(url, missing_ok: true, max_bytes: 64 * 1024**2) { |chunk| archive.write(chunk) }

        archive.flush
        Zip::File.open(archive.path) do |zip|
          entry = zip.entries.first
          unless zip.entries.size == 1 && entry.file? && entry.name == name && entry.size <= MAX_XML_BYTES
            raise Error, "Unexpected ZIP contents for #{name}"
          end
          entry.get_input_stream { |input| read_release(input, name, series, date) }
        end
      end
    end

    private

    def check_series!(series)
      raise Error, "Unknown RUIAN change series #{series}" unless SERIES.key?(series)
    end

    def release_date(filename, series)
      stamp = /\A(\d{8})_#{Regexp.escape(series)}\.xml\.zip\z/.match(filename.to_s)&.[](1)
      raise Error, "Invalid RUIAN #{series} release name #{filename.inspect}" unless stamp

      Date.strptime(stamp, '%Y%m%d')
    end

    def read_release(input, name, series, date)
      root = series == STANDARD ? 'VymennyFormat' : 'VymennyFormatAdres'
      records = []
      header = nil
      data = false
      data_section = nil
      top_section = nil
      options = Nokogiri::XML::ParseOptions::NONET
      Nokogiri::XML::Reader(input, nil, nil, options).each do |node|
        raise Error, "Unexpected document type in #{name}" if node.node_type == Nokogiri::XML::Reader::TYPE_DOCUMENT_TYPE
        next unless node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT

        case node.depth
        when 0
          unless node.local_name == root && node.namespace_uri == NAMESPACES.fetch(series)
            raise Error, "Unexpected XML root in #{name}"
          end
        when 1
          top_section = node.local_name
          header = xml_node(node) if top_section == 'Hlavicka'
          data = true if top_section == 'Data'
        when 2
          data_section = node.local_name if top_section == 'Data'
          if top_section == 'ZaniklePrvky' && node.local_name == 'ZaniklyPrvek'
            records << removed(xml_node(node))
          end
        when 3
          next unless top_section == 'Data'

          record = read_record(node, series, data_section)
          records << record if record
        end
      end
      unless data && header && text(header, 'TypSouboru') == series && text(header, 'TypDavky') == 'Prirustek' &&
          Date.iso8601(text(header, 'Datum').to_s[0, 10]) > date
        raise Error, "Invalid VFR header in #{name}"
      end

      Release.new("#{name}.zip", text(header, 'PredchoziSoubor'), records.compact)
    end

    def read_record(node, series, section)
      case [series, section, node.local_name]
      when [STANDARD, 'AdresniMista', 'AdresniMisto']
        feature = xml_node(node)
        point = feature.at_xpath("./*[local-name()='Geometrie']/*[local-name()='DefinicniBod']" \
          "//*[local-name()='pos' and namespace-uri()='http://www.opengis.net/gml/3.2']")
        attributes = address_numbers(feature).merge(zip: text(feature, 'Psc'))
        attributes[:point] = point.text.split.map { |value| Float(value) } if point
        Record.new(:address, code(feature, 'Kod'), attributes)
      when [ADDRESSES, 'Adresy', 'Adresa']
        feature = xml_node(node)
        type = text(feature, 'TypZmeny')
        raise Error, "Unknown address change type #{type.inspect}" unless %w[INSERT UPDATE].include?(type)

        attributes = address_numbers(feature).merge(
          city_code: code(feature, 'ObecKod'), city_name: text(feature, 'ObecNazev'),
          county_code: optional_code(feature, 'OkresKod'), part_code: optional_code(feature, 'CastObceKod'),
          part_name: text(feature, 'CastObceNazev'), street_name: text(feature, 'UliceNazev'),
          zip: text(feature, 'PostaKod')
        )
        Record.new(:address, code(feature, 'AdresniMistoKod'), attributes)
      when [STANDARD, 'ZaniklePrvky', 'ZaniklyPrvek']
        removed(xml_node(node))
      when [STANDARD, 'Obce', 'Obec']
        feature = xml_node(node)
        Record.new(:city, code(feature, 'Kod'), { name: text(feature, 'Nazev'), county_code: relation_code(feature, 'Okres') })
      when [STANDARD, 'Okresy', 'Okres']
        feature = xml_node(node)
        Record.new(:county, code(feature, 'Kod'), { name: text(feature, 'Nazev'), region_code: relation_code(feature, 'Vusc') })
      when [STANDARD, 'Vusc', 'Vusc']
        feature = xml_node(node)
        Record.new(:region, code(feature, 'Kod'), { name: text(feature, 'Nazev') })
      end
    end

    def removed(feature)
      case text(feature, 'TypPrvkuKod')
      when 'AD' then Record.new(:removed_address, code(feature, 'PrvekId'), {})
      when 'OB' then Record.new(:removed_city, code(feature, 'PrvekId'), {})
      end
    end

    def address_numbers(feature)
      orientation = text(feature, 'CisloOrientacni').to_s + text(feature, 'CisloOrientacniPismeno').to_s
      { house_number: code(feature, 'CisloDomovni'), orientation: orientation.empty? ? nil : orientation }
    end

    def relation_code(feature, element)
      child = feature.at_xpath("./*[local-name()='#{element}']")
      optional_code(child, 'Kod') if child
    end

    def code(feature, element)
      Integer(text(feature, element), 10)
    end

    def optional_code(feature, element)
      value = text(feature, element)
      Integer(value, 10) if value
    end

    def text(feature, element)
      feature.at_xpath("./*[local-name()='#{element}']")&.text
    end

    def xml_node(reader)
      Nokogiri::XML(reader.outer_xml) { |config| config.strict.nonet }.root
    end
  end
end
