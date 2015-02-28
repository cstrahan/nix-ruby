module Nix
  class Hash
    BASE32_CHARS = '0123456789abcdfghijklmnpqrsvwxyz'.freeze

    TYPES = [:md5, :sha1, :sha256]

    #---------------------------------------------------------------------------

    def self.assert_valid_type(type)
      unless TYPES.include?(type)
        fail "unknown hash type: #{type.inspect}"
      end
    end

    def self.hash_path(type, path, opts={})
      assert_valid_type(type)
      flat = opts[:flat] || false
      hash = `nix-hash --type #{hash_type.shellescape} #{flat ? "--flat" : ""} #{path.shellescape}`
      base16decode(type, hash)
    end

    #---------------------------------------------------------------------------

    attr_reader :raw

    def initialize(raw_str)
      self.raw = raw_str
    end

    def ==(other)
      self.type == other.type && self.raw == other.raw
    end

    def hash
      raw.hash ^ self.type
    end

    def base16encode
      raw.unpack('H*').first
    end

    def base32encode
      len = base32len(type)
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

    def self.base16decode(type, str)
      hash = str.scan(/../).map { |x| x.hex }.pack('c*')
      new(hash)
    end

    def self.base32len(type)
      (hash_size(type) * 8 - 1) / 5 + 1
    end

    def self.base32decode(type, str)
      hash = ""
      len = base32len(type)
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

    def self.hash_size(type)
      case type
      when :md5
        16
      when :sha1
        20
      when :sha256
        32
      end
    end
  end
end
