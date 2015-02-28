module Nix
  class Hash
    BASE32_CHARS = '0123456789abcdfghijklmnpqrsvwxyz'.freeze

    def self.hash_path(path, opts={})
      type = opts[:type] || :sha256
      flat = opts[:flat] || false
      cmd = "nix-hash --type #{hash_type.shellescape} #{flat ? "--flat" : ""} #{dir.shellescape}"
      if type == :sha256
        hash = `#{cmd}`
        Nix::Hash::SHA256.base16decode(hash)
      elsif type == :sha1
        hash = `#{cmd}`
        Nix::Hash::SHA1.base16decode(hash)
      elsif type == :md5
        hash = `#{cmd}`
        Nix::Hash::MD5.base16decode(hash)
      else
        fail "unknown hash type: #{type.inspect}"
      end
    end

    attr_reader :raw

    def initialize(raw_str)
      self.raw = raw_str
    end

    def ==(other)
      self.class == other.class && self.raw == other.raw
    end

    def hash
      raw.hash ^ self.class.hash
    end

    def base16encode
      raw.unpack('H*').first
    end

    def base32encode
      len = base32len()
      bytes = raw.bytes
      n = len - 1
      s = ""
      while n >= 0
        b = n * 5
        i = b / 8
        j = b % 8
        c = (bytes[i] >> j) | (i >= hash.hashSize - 1 ? 0 : bytes[i + 1] << (8 - j))
        s << BASE32_CHARS[c & 0x1f];
        n = n - 1
      end
      s
    end

    def self.base16decode(str)
      hash = str.scan(/../).map { |x| x.hex }.pack('c*')
      new(hash)
    end

    def self.base32len()
      (hash_size * 8 - 1) / 5 + 1
    end

    def self.base32decode(str)
      hash = ""
      len = base32len
      if str.bytesize != len
        fail "invalid base-32 hash #{str.inspect}"
      end

      while n < len
        c = str[len - n - 1]
        digit = BASE32_CHARS.index(c)
        if digit.nil?
          fail "invalid base-32 hash #{str.inspect}"
        end
        b = n * 5
        i = b / 8
        j = b % 8
        hash[i] = hash[i].ord | digit << j
        if i < hash_size - 1
          hash[i + 1] = hash[i + 1] | digit >> (8 - j)
        end

        new(hash)
      end

      return hash;
    end

    class MD5 < Hash
      def self.hash_size
        16
      end
    end

    class SHA1 < Hash
      def self.hash_size
        20
      end
    end

    class SHA256 < Hash
      def self.hash_size
        32
      end
    end
  end

  require "fileutils"
  module Prefetch
    class Git
      class Result
        attr_reader :hash
        attr_reader :full_revision
        attr_reader :path

        def initialize(attrs)
          attrs.each_pair do |key, val|
            instance_variable_set(:"@#{key}", val)
          end
        end
      end

      def fetch(url, rev)
        if expected_hash
          path = sh("nix-store --print-fixed-path --recursive #{hash_type.shellescape} #{expected_hash.shellescape} #{(name || "git-export").shellescape}").chomp

          unless Store.invalid_paths([path]).empty?
            return Result.new(
              :hash => expected_hash,
              :path => path,
            )
          end
        end

        Dir.mktmpdir do |dir|
          dir = File.join(dir, name || "git-export")
          FileUtils.mkdir_p(dir)

          # Perform the checkout.
          clone_user_rev(dir, url, rev)

          # Compute the hash.
          hash = sh("nix-hash --type #{hash_type.shellescape} --base32 #{dir.shellescape}")

          # Add the downloaded file to the Nix store.
          path = sh("nix-store --add-fixed --recursive #{hash_type.shellescape} #{dir.shellescape}")

          Result.new(attrs)
        end
      end

      private

      def clone(dir, url, hash, ref)
        hash, ref = resolve_hash_and_ref(hash, ref)

        Dir.chdir(dir) do
          # Initialize the repository.
          init_remote(url)

          # Download data from the repository.
          if !deep_clone && ref
            checkout_ref(hash, ref)
          else
            checkout_hash(hash, ref)
          end

          full_revision = sh("git rev-parse #{(hash || ref).shellescape} 2> /dev/null || git rev-parse refs/heads/fetchgit").split("\n").last

          # Checkout linked sources.
          if fetch_submodules
            init_submodules
          end
        end
      end

      def resolve_hash_and_ref(hash, ref)
        if !hash && ref
          hash = hash_from_ref(ref)
        elsif !ref && hash
          ref = ref_from_hash(hash)
        else
          fail "no hash or ref given"
        end
        [hash, ref]
      end

      def init_remote(url)
        sh "git init"
        sh "git remote add origin #{url}"
      end

      def ref_from_hash(hash)
        refs = sh "git ls-remote origin"
        line = refs.split("\n").detect { |line| line.split("\t")[0] == hash }
        if line
          line.split("\t")[1]
        end
      end

      def hash_from_ref(ref)
        refs = sh("git ls-remote origin").split("\n").compact
        line = refs.split("\n").detect { |line| line.split("\t")[1] == ref }
        if line
          line.split("\t")[0]
        end
      end

      def checkout_hash(hash, ref)
        sh "git fetch --progress origin"
        sh "git checkout -b fetchgit #{hash.shellescape}"
      end

      def checkout_ref(hash, ref)
        sh "git fetch --progress --depth 1 origin +#{ref.shellescape}"
        sh "git checkout -b fetchgit FETCH_HEAD"
      end

      def init_submodules
        # Add urls into .git/config file
        sh "git submodule init"

        # list submodule directories and their hashes
        lines = sh("git submodule status").split("\n")
        lines.each do |line|
          hash, dir = line.split(" ")
          settings = sh("git config -f .gitmodules --get-regexp 'submodule\\..*\\.path'").split("\n")
          settings.detect {|path| path =~ /^(.*)\.path #{dir}$/}
          dir = Regexp.last_match[1]
          clone(dir, url, hash, nil)
        end
      end

      def clone_user_rev(dir, url, rev)
        # Perform the checkout.
        if rev.start_with?("refs/")
          clone(dir, url, nil, rev)
        elsif rev =~ /^[0-9a-f]+$/
          clone(dir, url, rev, nil)
        end
      end

      def sh(cmd)
        stdout = `#{cmd}`
        unless $?.success?
          fail "shell command #{cmd.inspect} exitted with #{$?.exitstatus}"
        end
        return stdout.chomp
      end
    end
  end

  module Store
    module_function

    def fixed_path(path, hash_type, expected_hash, opts={})
      recursive = opts[:recursive] || false
      out = `nix-store --print-fixed-path #{recursive ? "--recursive" : ""} #{hash_type.shellescape} #{expected_hash.shellescape} #{name.shellescape})`
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
