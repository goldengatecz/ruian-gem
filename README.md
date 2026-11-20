# Ruian

RUIAN gem for downloading ČÚZK address data and passing it to an importer.

## Installation

Add this line to your application's Gemfile:

    gem 'ruian'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install ruian

## Usage

See example directory.

`Ruian::FilesUpdater` and `Ruian::EnumUpdater` download over verified HTTPS from
`vdp.cuzk.cz` and `vdp.cuzk.gov.cz`. Each archive has a `.manifest.json` sidecar
with its source URL, size and SHA-256. Keep the sidecar with the archive when
using `update!(remove: false)`; both are needed to reuse the download.

The updaters use rubyzip 3 to extract regular files from the relevant CSV tree
into a temporary directory, then replace the previous CSV tree. Extraction
limits are defined in `Ruian::ZipExtraction::LIMITS`. A failed update removes
the failed archive so the next attempt downloads a fresh copy.

You can import rows.

```
Ruian.new(importer: Importer.new).all    
```



## Contributing

1. Fork it ( https://github.com/simi/ruian/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
