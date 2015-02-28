Gem::Specification.new do |s|
  s.name        = 'nix-util'
  s.version     = '0.0.1'
  s.licenses    = ['MIT']
  s.homepage    = 'https://github.com/cstrahan/nix-ruby'
  s.summary     = "A Ruby API for the Nix package manager."
  s.description = "A Ruby API for the Nix package manager."
  s.authors     = ["Charles Strahan"]
  s.email       = 'charles@cstrahan.com'
  s.files       = Dir["lib/**/*.rb"]

  s.add_development_dependency 'rspec', '~> 3.2.0'
end
