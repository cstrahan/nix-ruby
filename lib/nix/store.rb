module Nix
  module Store
    module_function

    def fixed_path(hash, name, opts={})
      recursive = opts[:recursive] || false
      out = `nix-store --print-fixed-path #{recursive ? "--recursive" : ""} #{hash.type} #{hash.base32encode} #{name.shellescape})`
      out.chomp
    end

    def invalid_paths(paths)
      paths = Array(paths)
      paths = paths.map {|p| p.shellescape}.join(" ")
      out = `nix-store --check-validity --print-invalid #{paths} 2>&1`
      if $?.success?
        out.split("\n")
      else
        fail out
      end
    end
  end
end
