require 'ruian'

RSpec.describe Ruian::VfrChanges do
  let(:source) { described_class.new(http: http) }
  let(:http) { instance_double(Ruian::CuzkHttp) }
  let(:base_date) { Date.new(2026, 11, 16) }
  let(:series) { described_class::STANDARD }
  let(:header) { described_class::NAMESPACES.fetch(series) }

  def stub_release(day, previous)
    name = "202611#{day}_#{series}.xml"
    xml = <<~XML
      <vf:VymennyFormat xmlns:vf="#{header}">
        <vf:Hlavicka>
          <vf:TypDavky>Prirustek</vf:TypDavky><vf:TypSouboru>#{series}</vf:TypSouboru>
          <vf:Datum>2026-11-#{day + 1}T00:00:00</vf:Datum>
          <vf:PredchoziSoubor>202611#{previous}_#{series}.xml.zip</vf:PredchoziSoubor>
        </vf:Hlavicka>
        <vf:Data>
          <vf:AdresniMista><vf:AdresniMisto>
            <vf:Kod>80</vf:Kod><vf:CisloDomovni>21</vf:CisloDomovni><vf:Psc>11000</vf:Psc>
          </vf:AdresniMisto></vf:AdresniMista>
          <vf:ZaniklePrvky><vf:ZaniklyPrvek>
            <vf:TypPrvkuKod>AD</vf:TypPrvkuKod><vf:PrvekId>81</vf:PrvekId>
          </vf:ZaniklyPrvek></vf:ZaniklePrvky>
        </vf:Data>
      </vf:VymennyFormat>
    XML
    payload = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry(name)
      zip.write(xml)
    end.string
    allow(http).to receive(:get).with(a_string_ending_with(name + '.zip'), missing_ok: true, max_bytes: anything)
      .and_yield(payload).and_return(true)
  end

  before do
    allow(http).to receive(:get).with(a_string_ending_with("20261117_#{series}.xml.zip"),
      missing_ok: true, max_bytes: anything).and_return(false)
  end

  it 'accepts a skipped calendar day when the provider links to the confirmed release' do
    stub_release(18, 16)
    records = []
    result = source.each_release(series, snapshot_on: base_date, previous: nil, through: base_date + 2) do |release|
      records.concat(release.records)
    end
    expect(result).to eq('20261118_ST_ZZSZ.xml.zip')
    expect(records.map { |record| [record.type, record.code] }).to eq([[:address, 80], [:removed_address, 81]])
  end

  it 'rejects a missing predecessor without yielding the newer release' do
    stub_release(18, 17)
    expect do
      source.each_release(series, snapshot_on: base_date, previous: nil, through: base_date + 2) do
        raise 'Published a release with a missing predecessor'
      end
    end.to raise_error(described_class::Error, /Gap in RUIAN/)
  end
end
