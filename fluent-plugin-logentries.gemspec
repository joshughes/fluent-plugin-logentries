# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = "fluent-plugin-logentries"
  spec.version       = "0.2.12"
  spec.authors       = ["Joe Hughes"]
  spec.email         = ["dev@joehughes.info"]
  spec.summary       = "Logentries output plugin for Fluent event collector"
  spec.homepage      = "https://github.com/joshughes/fluent-plugin-logentries"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.5"
  spec.add_development_dependency "rake"
end
