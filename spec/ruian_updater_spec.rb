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
