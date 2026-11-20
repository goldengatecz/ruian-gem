require 'ruian'

RSpec.describe Ruian::FilesUpdater do
  around do |example|
    Dir.mktmpdir do |directory|
      @directory = Pathname.new(directory)
      example.run
    end
  end

  subject(:updater) { described_class.new(@directory) }

  it 'finds the previous month end without Rails' do
    expect(updater.most_recent_file(Time.utc(2024, 3, 1))).to eq('20240229')
    expect(updater.url).to match(%r{\Ahttps://vdp\.cuzk\.cz/vymenny_format/csv/\d{8}_OB_ADR_csv\.zip\z})
  end

  it 'restores the current CSV tree when publishing the extracted tree fails' do
    updater.csv_directory.mkpath
    updater.csv_directory.join('current.csv').write('current')
    Zip::File.open(updater.filepath, create: true) do |zip|
      zip.get_output_stream('CSV/replacement.csv') { |stream| stream.write('replacement') }
    end
    updater.send(:write_manifest)

    allow(File).to receive(:rename).and_call_original
    allow(File).to receive(:rename).with(
      satisfy { |path| path.basename.to_s == 'CSV' && path.dirname != @directory },
      updater.csv_directory
    ).and_raise(Errno::EIO)

    expect { updater.update! }.to raise_error(Errno::EIO)
    expect(updater.csv_directory.join('current.csv').read).to eq('current')
    expect(@directory.children).to contain_exactly(updater.csv_directory)
  end
end

RSpec.describe 'Monthly RUIAN release selection' do
  it 'keeps the requested URL when the month changes during a download and refreshes a kept older archive' do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      updater = Ruian::FilesUpdater.new(root)
      fixture = root.join('fixture.zip')
      Zip::File.open(fixture, create: true) do |archive|
        archive.get_output_stream('CSV/addresses.csv') { |output| output.write('addresses') }
      end
      payload = fixture.binread
      now = Time.utc(2026, 10, 31, 23, 59)
      allow(updater).to receive(:most_recent_file).and_wrap_original { |original| original.call(now) }

      requests = []
      connection = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:start).and_yield(connection)
      allow(connection).to receive(:request) do |request, &block|
        requests << request.uri.to_s
        now = Time.utc(2026, 11, 1)
        response = Net::HTTPOK.new('1.1', '200', 'OK')
        allow(response).to receive(:read_body).and_yield(payload)
        block.call(response)
      end

      updater.update!(remove: false)
      manifest = root.join('csv.zip.manifest.json')
      expect(JSON.parse(manifest.read).fetch('url')).to eq(requests.first)
      expect(requests.first).to include('/20260930_')
      expect(updater.csv_directory.join('addresses.csv').read).to eq('addresses')

      updater.update!(remove: false)
      expect(requests.size).to eq(2)
      expect(requests.last).to include('/20261031_')
      expect(JSON.parse(manifest.read).fetch('url')).to eq(requests.last)
    end
  end
end
